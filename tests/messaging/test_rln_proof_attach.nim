{.used.}

import std/[options, net, osproc]
import chronos, testutils/unittests, results, stew/byteutils
import
  logos_delivery/waku/[waku, waku_core, rln],
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/node/waku_node/relay,
  logos_delivery/waku/api/publish,
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/factory/waku_conf
import
  ../testlib/testasync,
  ../waku_rln_relay/utils_onchain,
  ../waku_rln_relay/rln/waku_rln_relay_utils

proc testConf(): WakuConf =
  var conf = MessagingClientConf()
    .toWakuNodeConf(messaging_conf.LogosDeliveryMode.Core).valueOr:
      raiseAssert error
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = Opt.some(3'u16)
  conf.numShardsInNetwork = 1
  conf.rest = false
  return conf.toWakuConf().valueOr:
    raiseAssert error

proc testMessage(): WakuMessage =
  WakuMessage(
    payload: "hello".toBytes(),
    contentTopic: "/test/1/attach/proto",
    timestamp: 1_700_000_000_000_000_000,
  )

suite "SendService RLN proof attach":
  asyncTest "passes the message through unproven when RLN is not mounted":
    ## The default (no-RLN) configuration must be unaffected: no proof is
    ## attached and the message reaches the send processors unchanged.
    let waku = (await Waku.new(testConf())).expect("Waku.new")
    let msg = testMessage()

    let attached = (await waku.attachRlnProof(msg)).expect("attachRlnProof")

    check:
      attached.proof.len == 0
      attached.payload == msg.payload
      attached.contentTopic == msg.contentTopic

  asyncTest "currentRlnEpochQuota is none when RLN is not mounted":
    ## The rate limit manager reads `none` as "use the wall-clock fallback".
    let waku = (await Waku.new(testConf())).expect("Waku.new")
    check waku.currentRlnEpochQuota().isNone()

suite "SendService RLN proof attach - RLN mounted":
  var
    waku {.threadvar.}: Waku
    anvilProc {.threadvar.}: Process
    manager {.threadvar.}: OnchainGroupManager

  asyncSetup:
    anvilProc = runAnvil(stateFile = Opt.some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

    waku = (await Waku.new(testConf())).expect("Waku.new")
    await waku.node.setRlnValidator(
      getWakuRlnConfig(
        manager = manager,
        userMessageLimit = 20,
        index = MembershipIndex(1),
        epochSizeSec = 600,
      )
    )

    let credentials = generateCredentials()
    (
      waitFor cast[OnchainGroupManager](waku.node.rln.groupManager).register(
        credentials, UserMessageLimit(20)
      )
    ).isOkOr:
      assert false, "failed to register RLN credentials: " & error

  asyncTeardown:
    ## The RLN proof-generator provider is registered on the global broker
    ## context; without stopping RLN it leaks into the next test's setup.
    try:
      await waku.node.rln.stop()
    except Exception:
      assert false, "failed to stop RLN: " & getCurrentExceptionMsg()
    stopAnvil(anvilProc)

  asyncTest "attaches a proof":
    let attached = (await waku.attachRlnProof(testMessage())).expect("attachRlnProof")

    check attached.proof.len > 0

  asyncTest "currentRlnEpochQuota reports RLN's epoch and user message limit":
    ## Wires the rate limit manager to RLN: the manager clamps its configured
    ## cap to `messageLimit` and rolls on `epochIndex`.
    let quota = waku.currentRlnEpochQuota()
    check:
      quota.isSome()
      quota.get().messageLimit == 20'u64 # the mounted userMessageLimit
      quota.get().epochIndex > 0'u64 # unixTime div epochSize, far from zero

  asyncTest "is idempotent: a message that already carries a proof is untouched":
    ## Pins the retry contract: the send service re-attaches on every round, so
    ## re-attaching must neither draw a fresh nonce nor change the bytes —
    ## otherwise a retried task would resend under a new nullifier.
    let first = (await waku.attachRlnProof(testMessage())).expect("first attach")
    let second = (await waku.attachRlnProof(first)).expect("second attach")

    check:
      first.proof.len > 0
      second.proof == first.proof
