import
  results,
  chronos,
  confutils,
  confutils/defs,
  confutils/std/net,
  confutils/toml/defs as confTomlDefs,
  confutils/toml/std/net as confTomlNet,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  secp256k1

import
  ../../tools/confutils/
    [cli_args, envvar as confEnvvarDefs, envvar_net as confEnvvarNet],
  waku/[common/logging, waku_core, waku_core/topics/pubsub_topic]

export confTomlDefs, confTomlNet, confEnvvarDefs, confEnvvarNet

const
  LitePubsubTopic* = PubsubTopic("/waku/2/rs/66/0")
  LiteContentTopic* = ContentTopic("/tester/1/light-pubsub-example/proto")
  DefaultMinTestMessageSizeStr* = "1KiB"
  DefaultMaxTestMessageSizeStr* = "150KiB"

type TesterFunctionality* = enum
  SENDER # pumps messages to the network
  RECEIVER # gather and analyze messages from the network

type LightpushVersion* = enum
  LEGACY # legacy lightpush protocol
  V3 # lightpush v3 protocol

type LiteProtocolTesterConf* = object
  configFile* {.
    desc:
      "Loads configuration from a TOML file (cmd-line parameters take precedence) for the light waku node",
    name: "config-file"
  .}: Option[InputFile]

  ## Log configuration
  logLevel* {.
    desc:
      "Sets the log level for process. Supported levels: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL",
    defaultValue: logging.LogLevel.DEBUG,
    name: "log-level"
  .}: logging.LogLevel

  logFormat* {.
    desc:
      "Specifies what kind of logs should be written to stdout. Supported formats: TEXT, JSON",
    defaultValue: logging.LogFormat.TEXT,
    name: "log-format"
  .}: logging.LogFormat

  ## Test configuration
  serviceNode* {.
    desc: "Peer multiaddr of the service node.", defaultValue: "", name: "service-node"
  .}: string

  bootstrapNode* {.
    desc:
      "Peer multiaddr of the bootstrap node. If `service-node` not set, it is used to retrieve potential service nodes of the network.",
    defaultValue: "",
    name: "bootstrap-node"
  .}: string

  nat* {.
    desc:
      "Specify method to use for determining public address. " &
      "Must be one of: any, none, upnp, pmp, extip:<IP>.",
    defaultValue: "any"
  .}: string

  testFunc* {.
    desc: "Specifies the lite protocol tester side. Supported values: sender, receiver.",
    defaultValue: TesterFunctionality.RECEIVER,
    name: "test-func"
  .}: TesterFunctionality

  lightpushVersion* {.
    desc: "Version of the sender to use. Supported values: legacy, v3.",
    defaultValue: LightpushVersion.LEGACY,
    name: "lightpush-version"
  .}: LightpushVersion

  numMessages* {.
    desc: "Number of messages to send.", defaultValue: 120, name: "num-messages"
  .}: uint32

  startPublishingAfter* {.
    desc: "Wait number of seconds before start publishing messages.",
    defaultValue: 5,
    name: "start-publishing-after"
  .}: uint32

  messageInterval* {.
    desc: "Delay between messages in milliseconds.",
    defaultValue: 1000,
    name: "message-interval"
  .}: uint32

  shard* {.desc: "Shards index to subscribe to. ", defaultValue: 0, name: "shard".}:
    uint16

  contentTopics* {.
    desc: "Default content topic to subscribe to. Argument may be repeated.",
    defaultValue: @[LiteContentTopic],
    name: "content-topic"
  .}: seq[ContentTopic]

  clusterId* {.
    desc:
      "Cluster id that the node is running in. Node in a different cluster id is disconnected.",
    defaultValue: 0,
    name: "cluster-id"
  .}: uint16

  minTestMessageSize* {.
    desc:
      "Minimum message size. Accepted units: KiB, KB, and B. e.g. 1024KiB; 1500 B; etc.",
    defaultValue: DefaultMinTestMessageSizeStr,
    name: "min-test-msg-size"
  .}: string

  maxTestMessageSize* {.
    desc:
      "Maximum message size. Accepted units: KiB, KB, and B. e.g. 1024KiB; 1500 B; etc.",
    defaultValue: DefaultMaxTestMessageSizeStr,
    name: "max-test-msg-size"
  .}: string
  ## Tester REST service configuration
  restAddress* {.
    desc: "Listening address of the REST HTTP server.",
    defaultValue: IpAddress(family: IpAddressFamily.IPv4, address_v4: [127'u8, 0, 0, 1]),
    name: "rest-address"
  .}: IpAddress

  testPeers* {.
    desc: "Run dial test on gathered PeerExchange peers.",
    defaultValue: false,
    name: "test-peers"
  .}: bool

  reqPxPeers* {.
    desc: "Number of peers to request on PeerExchange.",
    defaultValue: 100,
    name: "req-px-peers"
  .}: uint16

  restPort* {.
    desc: "Listening port of the REST HTTP server.",
    defaultValue: 8654,
    name: "rest-port"
  .}: uint16

  fixedServicePeer* {.
    desc:
      "Prevent changing the service peer in case of failures, the full test will stict to the first service peer in use.",
    defaultValue: false,
    name: "fixed-service-peer"
  .}: bool

  restAllowOrigin* {.
    desc:
      "Allow cross-origin requests from the specified origin." &
      "Argument may be repeated." & "Wildcards: * or ? allowed." &
      "Ex.: \"localhost:*\" or \"127.0.0.1:8080\"",
    defaultValue: @["*"],
    name: "rest-allow-origin"
  .}: seq[string]

  metricsPort* {.
    desc: "Listening port of the Metrics HTTP server.",
    defaultValue: 8003,
    name: "metrics-port"
  .}: uint16

{.push warning[ProveInit]: off.}

proc load*(T: type LiteProtocolTesterConf, version = ""): ConfResult[T] =
  try:
    let conf = LiteProtocolTesterConf.load(
      version = version,
      secondarySources = proc(
          conf: LiteProtocolTesterConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile("liteprotocoltester")),
    )
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

proc getPubsubTopic*(conf: LiteProtocolTesterConf): PubsubTopic =
  return $RelayShard(clusterId: conf.clusterId, shardId: conf.shard)

proc getCodec*(conf: LiteProtocolTesterConf): string =
  return
    if conf.testFunc == TesterFunctionality.RECEIVER:
      WakuFilterSubscribeCodec
    else:
      if conf.lightpushVersion == LightpushVersion.LEGACY:
        WakuLegacyLightPushCodec
      else:
        WakuLightPushCodec

{.pop.}
