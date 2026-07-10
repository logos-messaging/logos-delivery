## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import std/[options, net]
import results, chronos
import confutils/defs
import libp2p/crypto/crypto
import logos_delivery/waku/common/logging
import logos_delivery/api/conf/kernel_conf
import chronicles
import
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/waku,
  logos_delivery/waku/factory/conf_builder/waku_conf_builder,
  logos_delivery/messaging/delivery_service/[recv_service, send_service]

# Surfaces the messaging API interface (and its Message* events) to consumers.
export messaging_client_api

type
  MessagingClientConf* = object
    clusterId* {.name: "cluster-id".}: Option[uint16] ## Network cluster id.
    numShardsInCluster* {.name: "num-shards-in-network".}: Option[uint16]
      ## Number of shards in the cluster.
    p2pTcpPort* {.name: "tcp-port".}: Option[Port] ## TCP listening port.
    discv5UdpPort* {.name: "discv5-udp-port".}: Option[Port] ## discv5 UDP port.
    websocketSupport* {.name: "websocket-support".}: Option[bool]
      ## Enable the websocket transport.
    websocketPort* {.name: "websocket-port".}: Option[Port] ## Websocket listening port.
    quicSupport* {.name: "quic-support".}: Option[bool] ## Enable the QUIC transport.
    quicPort* {.name: "quic-port".}: Option[Port] ## QUIC (UDP) listening port.
    listenIpv4* {.name: "listen-address".}: Option[IpAddress] ## Inbound bind address.
    maxMessageSize* {.name: "max-msg-size".}: Option[string]
      ## Maximum accepted message size (e.g. "150 KiB").
    entryNodes* {.name: "entry-node".}: Option[seq[string]]
      ## Bootstrap / connectivity nodes (enrtree or multiaddr).
    ethRpcEndpoints* {.name: "rln-relay-eth-client-address".}: Option[seq[EthRpcUrl]]
      ## Ethereum RPC endpoints (required for RLN validation); multiple for fail-over.
    rlnContractAddress* {.name: "rln-relay-eth-contract-address".}: Option[string]
      ## RLN contract address; when set, RLN validation is enabled.
    rlnChainId* {.name: "rln-relay-chain-id".}: Option[uint]
      ## Chain id the RLN contract is deployed on.
    rlnEpochSizeSec* {.name: "rln-relay-epoch-sec".}: Option[uint]
      ## RLN epoch size, in seconds.
    reliabilityEnabled* {.name: "reliability".}: Option[bool]
      ## Enable store-based send reliability.
    store*: Option[bool] ## Enable the store protocol.
    storenode* {.name: "storenode".}: Option[string]
    storeMessageDbUrl* {.name: "store-message-db-url".}: Option[string]
      ## Database connection URL for the store service's persistent storage.
    storeMessageRetentionPolicy* {.name: "store-message-retention-policy".}:
      Option[string] ## Store retention policy (e.g. "time:3600;size:1GB").
    storeMaxNumDbConnections* {.name: "store-max-num-db-connections".}: Option[int]
      ## Maximum number of simultaneous store database connections.
    logLevel* {.name: "log-level".}: Option[logging.LogLevel]
      ## Process log level (TRACE..FATAL); applied by the kernel on node creation.
    logFormat* {.name: "log-format".}: Option[logging.LogFormat]
      ## Process log format (TEXT or JSON); applied by the kernel on node creation.
    nodeKey* {.name: "nodekey".}: Option[crypto.PrivateKey]
      ## P2P node private key (64-char hex): stable identity / peerId across restarts.

  MessagingClient* = ref object
    brokerCtx*: BrokerContext
    waku*: Waku ## The Waku kernel this layer drives; read by `messaging/api/*`.
    sendService*: SendService
    recvService*: RecvService
    started*: bool

proc new*(
    T: type MessagingClient, conf: MessagingClientConf, waku: Waku
): Result[T, string] =
  ## The messaging layer chains onto Waku: it drives the underlying Waku kernel
  ## for transport while exposing its own send/recv API.
  let reliability = conf.reliabilityEnabled.get(DefaultP2pReliability)
  let sendService = ?SendService.new(reliability, waku)
  let recvService = RecvService.new(waku)
  return ok(
    T(
      waku: waku,
      sendService: sendService,
      recvService: recvService,
      brokerCtx: waku.brokerCtx,
    )
  )

proc checkApiAvailability*(self: MessagingClient): Result[void, string] =
  ## Shared guard for the api operation module.
  if self.isNil():
    return err("MessagingClient is not initialized")

  return ok()
