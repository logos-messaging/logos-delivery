{.used.}

import std/[options, osproc, times]
import chronos, testutils/unittests, results, stew/byteutils
import
  logos_delivery/waku/[waku, waku_core, rln],
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/node/waku_node/relay,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/api/rln as rln_api,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/rln/rln_lez/[rln_lez, transport]
import
  ../testlib/[testasync, wakunodeconf],
  ../waku_rln_relay/utils_onchain,
  ../waku_rln_relay/rln/waku_rln_relay_utils

proc testConf(): WakuConf =
  defaultTestWakuNodeConf().toWakuConf().valueOr:
    raiseAssert error

proc testMessage(): WakuMessage =
  WakuMessage(
    payload: "hello".toBytes(),
    contentTopic: "/test/1/attach/proto",
    timestamp: 1_700_000_000_000_000_000,
  )

proc nowSec(): uint64 =
  uint64(getTime().toUnix())

const LezQuotaReply =
  """{"error":null,"success":true,"value":{"epoch_index":42,"rate_limit":100,"remaining":7}}"""

proc lezGetQuota(
    reqId: uint64, timestamp: uint64, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    discard logosdelivery_rln_response(reqId, LezQuotaReply.cstring)

var lezPlugin = LogosDeliveryRlnPlugin(get_epoch_quota: lezGetQuota)

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

  asyncTest "rlnEpochQuota fails when RLN is not mounted":
    ## The rate limit manager reads the failure as "use the local fallback".
    let waku = (await Waku.new(testConf())).expect("Waku.new")
    check (await waku.rlnEpochQuota(MembershipScope(), nowSec())).isErr()

  asyncTest "rlnEpochQuota reads the RLN plugin's budget when it is mounted":
    let waku = (await Waku.new(testConf())).expect("Waku.new")
    check logosdelivery_rln_set_plugin(addr lezPlugin, nil) == 0
    defer:
      discard logosdelivery_rln_set_plugin(nil, nil)
    waku.node.rlnLez = RlnLez.init()

    let quota = (await waku.rlnEpochQuota(MembershipScope(), nowSec())).valueOr:
      raiseAssert error
    check:
      quota.epochIndex == 42
      quota.rateLimit == 100
      quota.remaining == 7

suite "SendService RLN proof attach - RLN mounted":
  var
    waku {.threadvar.}: Waku
    anvilProc {.threadvar.}: Process
    manager {.threadvar.}: RlnEvmGroupManager

  asyncSetup:
    anvilProc = runAnvil(stateFile = Opt.some(DEFAULT_ANVIL_STATE_PATH))
    manager = await setupRlnEvm(deployContracts = false)

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
      await cast[RlnEvmGroupManager](waku.node.rln.groupManager).register(
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

  asyncTest "rlnEpochQuota's remaining budget drops as proofs spend it":
    ## Wires the rate limit manager to RLN: admission stops at
    ## `remaining == 0` and the window rolls on `epochIndex`.
    let before =
      (await waku.rlnEpochQuota(MembershipScope(), nowSec())).expect("rlnEpochQuota")
    discard (await waku.attachRlnProof(testMessage())).expect("attachRlnProof")
    let after =
      (await waku.rlnEpochQuota(MembershipScope(), nowSec())).expect("rlnEpochQuota")
    check:
      before.rateLimit == 20'u64 # the mounted userMessageLimit
      before.remaining == 20'u64
      before.epochIndex > 0'u64 # unixTime div epochSize, far from zero
      after.remaining == 19'u64

  asyncTest "is idempotent: a message that already carries a proof is untouched":
    ## Pins the retry contract: the send service re-attaches on every round, so
    ## re-attaching must neither draw a fresh nonce nor change the bytes —
    ## otherwise a retried task would resend under a new nullifier.
    let first = (await waku.attachRlnProof(testMessage())).expect("first attach")
    let second = (await waku.attachRlnProof(first)).expect("second attach")

    check:
      first.proof.len > 0
      second.proof == first.proof
