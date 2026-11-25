{.used.}

import std/json
import chronos, results, testutils/unittests, libp2p_mix/curve25519
import libp2p/crypto/curve25519
import libp2p/protocols/connectivity/autonat/types as autonat_types
import mix_rln_spam_protection/module_api
import
  logos_delivery/waku/[
    waku_core,
    rln/types,
    net/bound_ports,
    node/waku_node,
    node/waku_node/mix_rln,
    node/waku_node/relay,
    discovery/self_advert_brokers,
  ],
  ../testlib/[wakucore, wakunode]

const
  MixRegistry = "logos:local:mix"
  MixIdentifierHex = "6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000"

type FakeRlnModule = ref object
  state: string ## What `get_membership_state` answers; empty fails the call.
  calls: seq[tuple[methodName: string, args: JsonNode]]

proc call(module: FakeRlnModule): RlnModuleCall =
  return proc(
      methodName: string, args: JsonNode
  ): Future[Result[JsonNode, string]] {.async: (raises: [CancelledError]).} =
    module.calls.add((methodName, args))
    if methodName == "get_registry_parameters":
      # The Mix profile the plugin checks at its start.
      return ok(%*{"epoch_size_sec": 10, "max_epoch_gap": 3})
    if methodName != "get_membership_state":
      return err("unexpected call: " & methodName)
    if module.state.len == 0:
      return err("backend is down")
    return ok(%*{"state": module.state})

proc mixRln(module: FakeRlnModule): ModuleRlnProtection =
  ModuleRlnProtection
    .new(
      ModuleRlnConfig(
        registryId: MixRegistry,
        rlnIdentifierHex: MixIdentifierHex,
        epochSeconds: 10,
        maxEpochGap: 3,
        metadataTopic: "/test/1/mix-rln-metadata/proto",
      ),
      module.call(),
    )
    .expect("a valid Mix RLN config")

suite "Waku Mix RLN - membership":
  asyncTest "the membership is read on the Mix scope":
    let module = FakeRlnModule(state: "active")

    let status = (await module.mixRln().readMixMembership()).expect("an answer")

    check:
      status == MembershipStatus.Active
      module.calls.len == 1
      module.calls[0].methodName == "get_membership_state"
      module.calls[0].args == %*[MixRegistry, MixIdentifierHex]

  asyncTest "a membership that is not active yet is reported as it is":
    let module = FakeRlnModule(state: "pending")

    let status = (await module.mixRln().readMixMembership()).expect("an answer")

    check:
      status == MembershipStatus.Pending
      not status.isUsable()

  asyncTest "a backend that does not answer is an error, not a missing membership":
    let module = FakeRlnModule(state: "")

    let read = await module.mixRln().readMixMembership()

    check:
      read.isErr()
      read.error.failure == MixMembershipReadFailure.NoAnswer

  asyncTest "a state this node does not know is an answer of its own, not a missed one":
    let module = FakeRlnModule(state: "some-new-state")

    let read = await module.mixRln().readMixMembership()

    check:
      read.isErr()
      read.error.failure == MixMembershipReadFailure.UnknownState
      read.error.state == "some-new-state"

proc nodeWith(module: FakeRlnModule, changes: ref int): WakuNode =
  let node = WakuNode(ports: BoundPorts.init(), wakuMixRln: module.mixRln())
  ## `changes` counts the reports that this node's record changed. A report
  ## reaches a listener on a later turn of the event loop, so a test waits.
  let listening = AdvertChangedEvent.listenIt(node.advertCtx):
    inc changes[]
  discard listening.expect("listens")
  return node

suite "Waku Mix RLN - membership changes":
  asyncTest "a membership that becomes usable is reported once":
    let
      module = FakeRlnModule(state: "pending")
      changes = new int
      node = module.nodeWith(changes)

    await node.refreshMixMembership()
    await sleepAsync(chronos.milliseconds(10))
    check:
      not node.mixMembershipUsable
      changes[] == 0

    module.state = "active"
    await node.refreshMixMembership()
    await node.refreshMixMembership()
    await sleepAsync(chronos.milliseconds(10))
    check:
      node.mixMembershipUsable
      changes[] == 1

  asyncTest "a membership that stops being usable is reported":
    let
      module = FakeRlnModule(state: "active")
      changes = new int
      node = module.nodeWith(changes)
    await node.refreshMixMembership()

    module.state = "expired"
    await node.refreshMixMembership()
    await sleepAsync(chronos.milliseconds(10))

    check:
      not node.mixMembershipUsable
      changes[] == 2

  asyncTest "an unanswered check keeps the last known answer":
    let
      module = FakeRlnModule(state: "active")
      changes = new int
      node = module.nodeWith(changes)
    await node.refreshMixMembership()

    module.state = ""
    await node.refreshMixMembership()
    await sleepAsync(chronos.milliseconds(10))

    check:
      node.mixMembershipUsable
      changes[] == 1

  asyncTest "an unknown state keeps the last known answer and is remembered until a known one":
    let
      module = FakeRlnModule(state: "active")
      changes = new int
      node = module.nodeWith(changes)
    await node.refreshMixMembership()

    module.state = "revoked"
    await node.refreshMixMembership()
    await node.refreshMixMembership()
    check:
      node.mixMembershipUsable
      changes[] == 1
      node.mixMembershipUnknownState == Opt.some("revoked")

    module.state = "expired"
    await node.refreshMixMembership()
    check:
      not node.mixMembershipUsable
      changes[] == 2
      node.mixMembershipUnknownState.isNone()

  asyncTest "an unanswered check after an unknown state keeps both":
    let
      module = FakeRlnModule(state: "revoked")
      changes = new int
      node = module.nodeWith(changes)
    await node.refreshMixMembership()

    module.state = ""
    await node.refreshMixMembership()

    check:
      not node.mixMembershipUsable
      changes[] == 0
      node.mixMembershipUnknownState == Opt.some("revoked")

suite "Waku Mix RLN - readiness to advertise":
  test "a node without Mix RLN is ready":
    check WakuNode(ports: BoundPorts.init()).mixAdvertReady()

  test "a node with Mix RLN is ready only with a usable membership":
    let node = WakuNode(
      ports: BoundPorts.init(), wakuMixRln: FakeRlnModule(state: "active").mixRln()
    )
    check not node.mixAdvertReady()

    node.mixMembershipUsable = true
    check node.mixAdvertReady()

  asyncTest "the Rendezvous record carries the mix key only when the node is ready":
    check WakuNode(ports: BoundPorts.init()).rendezvousMixKey().len == 0

    let node = newTestWakuNode(generateSecp256k1Key())
    let mixKeys = generateKeyPair().expect("mix key pair")
    (await node.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay: " & $error
    (
      await node.mountMix(
        DefaultClusterId, mixKeys.privateKey, @[], allowAllAddresses = true
      )
    ).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    node.wakuMixRln = FakeRlnModule(state: "active").mixRln()
    check:
      node.advertisedMixKey().isNone()
      node.rendezvousMixKey().len == 0

    node.mixMembershipUsable = true
    check:
      node.advertisedMixKey() == Opt.some(mixKeys.publicKey)
      node.rendezvousMixKey() == mixKeys.publicKey.to0xHex()

    node.wakuMixRln = nil
    node.mixMembershipUsable = false
    check node.rendezvousMixKey() == mixKeys.publicKey.to0xHex()

suite "Waku Mix RLN - a node without Relay":
  asyncTest "starts without Relay RLN and without coordination":
    let
      module = FakeRlnModule(state: "active")
      changes = new int
      node = module.nodeWith(changes)
    check:
      node.wakuRelay.isNil()
      node.rlnPlugin.isNone()

    # The node has no subscription manager: a subscription to the metadata
    # topic would fail the start.
    let started = await node.startMixRln()

    check:
      started.isOk()
      node.mixMembershipUsable
      node.wakuMixRlnListener.isNone()
    await node.stopMixRln()

  asyncTest "still reads its Mix membership":
    let
      module = FakeRlnModule(state: "pending")
      changes = new int
      node = module.nodeWith(changes)

    check (await node.startMixRln()).isOk()

    check:
      not node.mixMembershipUsable
      module.calls[^1].methodName == "get_membership_state"
      module.calls[^1].args == %*[MixRegistry, MixIdentifierHex]
    await node.stopMixRln()

proc newMixNode(
    relay: bool, allowAllAddresses: bool
): Future[(WakuNode, Curve25519Key)] {.async.} =
  ## A node that mounts mix, with or without relay, and its mix public key.
  let node = newTestWakuNode(generateSecp256k1Key())
  if relay:
    (await node.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay: " & $error
  let mixKeys = generateKeyPair().expect("mix key pair")
  (
    await node.mountMix(
      DefaultClusterId, mixKeys.privateKey, @[], allowAllAddresses = allowAllAddresses
    )
  ).isOkOr:
    raiseAssert "Failed to mount mix: " & $error
  return (node, mixKeys.publicKey)

suite "Waku Mix - a hop for others":
  asyncTest "a node without relay advertises no mix key, and can still prove":
    let (node, _) = await newMixNode(relay = false, allowAllAddresses = true)

    check:
      node.mixAdvertReady()
      not node.mixHopReady()
      node.advertisedMixKey().isNone()
      node.rendezvousMixKey().len == 0

  asyncTest "a relay node advertises its mix key only while AutoNAT reports it reachable":
    let (node, mixKey) = await newMixNode(relay = true, allowAllAddresses = false)
    check:
      node.mixReachability == NetworkReachability.Unknown
      not node.mixHopReady()
      node.advertisedMixKey().isNone()

    node.setMixReachability(NetworkReachability.Reachable)
    check:
      node.mixHopReady()
      node.advertisedMixKey() == Opt.some(mixKey)
      node.rendezvousMixKey() == mixKey.to0xHex()

    node.setMixReachability(NetworkReachability.NotReachable)
    check:
      not node.mixHopReady()
      node.advertisedMixKey().isNone()
      node.mixAdvertReady()

  asyncTest "with allowAllAddresses a relay node does not wait for AutoNAT":
    let (node, mixKey) = await newMixNode(relay = true, allowAllAddresses = true)

    check:
      node.mixReachability == NetworkReachability.Unknown
      node.mixHopReady()
      node.advertisedMixKey() == Opt.some(mixKey)

  asyncTest "only a change of reachability reports a record change":
    let
      (node, _) = await newMixNode(relay = true, allowAllAddresses = false)
      changes = new int
    let listening = AdvertChangedEvent.listenIt(node.advertCtx):
      inc changes[]
    discard listening.expect("listens")

    node.setMixReachability(NetworkReachability.Reachable)
    node.setMixReachability(NetworkReachability.Reachable)
    await sleepAsync(chronos.milliseconds(10))
    check changes[] == 1

    node.setMixReachability(NetworkReachability.NotReachable)
    await sleepAsync(chronos.milliseconds(10))
    check changes[] == 2
