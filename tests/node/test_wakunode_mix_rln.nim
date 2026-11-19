{.used.}

import std/json
import chronos, results, testutils/unittests
import mix_rln_spam_protection/module_api
import logos_delivery/waku/[rln/types, node/waku_node/mix_rln]

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

    check (await module.mixRln().readMixMembership()).isErr()

  asyncTest "a state this node does not know is an error":
    let module = FakeRlnModule(state: "some-new-state")

    check (await module.mixRln().readMixMembership()).isErr()
