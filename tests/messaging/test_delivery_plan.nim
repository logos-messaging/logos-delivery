{.used.}

import std/[sequtils, setutils], results, testutils/unittests

import
  logos_delivery/api/conf/modes,
  logos_delivery/messaging/delivery_service/send_service/delivery_plan

## Tests of the plans that the configs build.
## `deliver` moves a task along these transitions.
## A trigger with no transition fails the send.

proc planOf(
    level: AnonymityLevel, transports: set[DeliveryState], resend = true
): DeliveryPlan =
  buildDeliveryPlan(level, transports, resend).expect("delivery plan")

func toState(
    plan: DeliveryPlan, state: DeliveryState, trigger: Trigger, facts: set[Guard] = {}
): Opt[DeliveryState] =
  let transition = plan.transition(state, trigger, facts).valueOr:
    return Opt.none(DeliveryState)
  Opt.some(transition.toState)

func hasResend(plan: DeliveryPlan): bool =
  plan.transitions.anyIt(it.fromState == DeliveryState.StoreResend)

iterator factSets(): set[Guard] =
  ## Each set of guard facts.
  for bits in 0 ..< (1 shl (Guard.high.ord + 1)):
    var facts: set[Guard]
    for guard in Guard:
      if (bits and (1 shl guard.ord)) != 0:
        facts.incl(guard)
    yield facts

func fixedToState(
    plan: DeliveryPlan, state: DeliveryState, trigger: Trigger
): Opt[DeliveryState] =
  ## The to state of `trigger` out of `state`, when no guard changes it.
  let unguarded = plan.toState(state, trigger)
  for facts in factSets():
    if plan.toState(state, trigger, facts) != unguarded:
      return Opt.none(DeliveryState)
  unguarded

const
  PlainTransports = {DeliveryState.Relay, DeliveryState.Lightpush}
  AllTransports = {DeliveryState.Mix, DeliveryState.Relay, DeliveryState.Lightpush}

iterator configs(): (AnonymityLevel, set[DeliveryState], bool) =
  for level in AnonymityLevel:
    for transports in [
      {DeliveryState.Relay},
      {DeliveryState.Lightpush},
      PlainTransports,
      {DeliveryState.Mix},
      AllTransports,
      {DeliveryState.Mix, DeliveryState.Lightpush},
      {DeliveryState.Mix, DeliveryState.Relay},
    ]:
      for resend in [false, true]:
        yield (level, transports, resend)

proc firedFrom(
    plan: DeliveryPlan, state: DeliveryState, restarts = true
): seq[Opt[Transition]] =
  ## The transition of each trigger that `state` can get, under each set of facts.
  ## With `restarts`, the state also gets `Started`.
  var triggers = plan.stepTriggers(state)
  if restarts:
    triggers.incl(Trigger.Started)
  var fired: seq[Opt[Transition]]
  for trigger in triggers:
    for facts in factSets():
      fired.add(plan.transition(state, trigger, facts))
  fired

proc reachable(
    plan: DeliveryPlan, start = DeliveryState.Initial, restarts = true
): set[DeliveryState] =
  var reached = {start}
  var queue = @[start]
  while queue.len > 0:
    let state = queue.pop()
    for fired in plan.firedFrom(state, restarts):
      if fired.isSome() and fired.get().toState notin reached:
        reached.incl(fired.get().toState)
        if not fired.get().toState.isFinal():
          queue.add(fired.get().toState)
  reached

type
  PlanTask = ref object ## The fields of a task that `move` writes.
    state: DeliveryState
    lastReport: Opt[StepReport]

  PlanShell = ref object
    ## A shell with fixed guard facts. It records what the plan asks it to do.
    facts: set[Guard]
    ran: seq[string] ## The name of each effect, in the sequence of the runs.
    unplanned: seq[(DeliveryState, Trigger)]

proc holds(shell: PlanShell, task: PlanTask, guard: Guard): bool =
  guard in shell.facts

proc runEffect(
    shell: PlanShell, task: PlanTask, effect: TransitionEffect, report: StepReport
) =
  shell.ran.add($effect)

proc runEffect(
    shell: PlanShell, task: PlanTask, effect: StateEffect, report: StepReport
) =
  shell.ran.add($effect)

proc unplanned(
    shell: PlanShell, task: PlanTask, fromState: DeliveryState, trigger: Trigger
): DeliveryState =
  shell.unplanned.add((fromState, trigger))
  DeliveryState.NotPropagated

suite "Delivery plan":
  test "each trigger that a reachable state can get fires a transition in each plan":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        check:
          case level
          of AnonymityLevel.None:
            transports * PlainTransports == {}
          of AnonymityLevel.Preferred:
            DeliveryState.Mix notin transports or transports * PlainTransports == {}
          of AnonymityLevel.Required:
            DeliveryState.Mix notin transports
        continue
      let plan = built.get()
      for state in plan.reachable() - FinalStates:
        for fired in plan.firedFrom(state):
          checkpoint($level & " " & $transports & " " & $resend & " " & $state)
          check fired.isSome()

  test "each reachable state can run its step and can reach a final state":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        continue
      let plan = built.get()
      let reached = plan.reachable()
      checkpoint($level & " " & $transports & " " & $resend)
      check:
        reached * {DeliveryState.Relay, DeliveryState.Lightpush, DeliveryState.Mix} <=
          plan.chain.toSet()
        DeliveryState.StoreResend notin reached or plan.hasResend()
        plan.transitions.allIt(it.toState != DeliveryState.Initial)
      # A send gets to its end with no restart.
      for state in reached - {DeliveryState.Initial}:
        check plan.reachable(state, restarts = false) * FinalStates != {}

  test "each transition starts in a state that the plan can reach":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        continue
      let plan = built.get()
      let reached = plan.reachable()
      for transition in plan.transitions:
        checkpoint($level & " " & $transports & " " & $resend & ": " & $transition)
        check transition.fromState in reached

  test "each transition fires only on triggers that its from state can get":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        continue
      let plan = built.get()
      for transition in plan.transitions:
        checkpoint($level & " " & $transports & " " & $resend & ": " & $transition)
        check transition.triggers <=
          plan.stepTriggers(transition.fromState) + {Trigger.Started}

  test "a trigger is listed only for the steps that can report it":
    ## Only the check of a lightpush peer gives `NoLightpushPeer`.
    ## Only a `Required` node checks the size before the admission.
    let required = planOf(AnonymityLevel.Required, {DeliveryState.Mix})
    let preferred = planOf(AnonymityLevel.Preferred, AllTransports)
    let sizeFailures = {Trigger.ProofSizeUnknown, Trigger.TooLargeForMix}
    check:
      Trigger.NoLightpushPeer notin preferred.stepTriggers(DeliveryState.Mix)
      Trigger.NoLightpushPeer notin preferred.stepTriggers(DeliveryState.Relay)
      Trigger.NoLightpushPeer in preferred.stepTriggers(DeliveryState.Lightpush)
      Trigger.NoLightpushPeer in preferred.stepTriggers(DeliveryState.StoreResend)
      preferred.stepTriggers(DeliveryState.Prove) * sizeFailures == {}
      sizeFailures <= required.stepTriggers(DeliveryState.Prove)
      Trigger.AttemptTimedOut notin preferred.stepTriggers(DeliveryState.Lightpush)
      Trigger.AttemptTimedOut in preferred.stepTriggers(DeliveryState.StoreResend)

  test "Required never takes the plain path, and a mix publish never waits for Store":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        continue
      let plan = built.get()
      if level == AnonymityLevel.Required:
        check plan.reachable() * {
          DeliveryState.Relay, DeliveryState.Lightpush, DeliveryState.StoreResend,
          DeliveryState.AwaitingStore,
        } == {}
      for transition in plan.transitions:
        if transition.fromState == DeliveryState.Mix and
            Trigger.Published in transition.triggers:
          check transition.toState notin StoreWaitStates

  test "no transition has the zero value of a report":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        continue
      for state in DeliveryState:
        for facts in factSets():
          check built.get().transition(state, Trigger.Unreported, facts).isNone()

  test "each transition fires while its guards hold":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        continue
      let plan = built.get()
      for transition in plan.transitions:
        for trigger in transition.triggers:
          checkpoint($transition)
          check plan.transition(transition.fromState, trigger, transition.guards) ==
            Opt.some(transition)

  test "a final state has no transition, and only a final state finishes the task":
    for (level, transports, resend) in configs():
      let built = buildDeliveryPlan(level, transports, resend)
      if built.isErr():
        continue
      for transition in built.get().transitions:
        check transition.fromState notin FinalStates
    for state in DeliveryState:
      check (StateEffect.Finish in stateEffects(state)) == state.isFinal()

  test "the config sets the chain":
    check:
      planOf(AnonymityLevel.None, PlainTransports).chain ==
        @[DeliveryState.Relay, DeliveryState.Lightpush]
      planOf(AnonymityLevel.None, {DeliveryState.Relay}).chain == @[DeliveryState.Relay]
      planOf(AnonymityLevel.None, {DeliveryState.Lightpush}).chain ==
        @[DeliveryState.Lightpush]
      planOf(AnonymityLevel.Preferred, AllTransports).chain ==
        @[DeliveryState.Mix, DeliveryState.Relay, DeliveryState.Lightpush]
      planOf(AnonymityLevel.Required, AllTransports).chain == @[DeliveryState.Mix]
      buildDeliveryPlan(AnonymityLevel.Required, PlainTransports, true).isErr()
      buildDeliveryPlan(AnonymityLevel.Preferred, PlainTransports, true).isErr()
      buildDeliveryPlan(AnonymityLevel.Preferred, {DeliveryState.Mix}, true).isErr()
      buildDeliveryPlan(AnonymityLevel.None, {}, true).isErr()

  test "Required has no transition to the plain path and no resend":
    let plan = planOf(AnonymityLevel.Required, AllTransports)
    check not plan.hasResend()
    for transition in plan.transitions:
      check transition.toState notin {DeliveryState.Relay, DeliveryState.Lightpush}

  test "Required waits for an unusable mix within the grace and fails a message too large for mix":
    let plan = planOf(AnonymityLevel.Required, {DeliveryState.Mix})
    for trigger in MixUnusableTriggers - {Trigger.MixNotMounted}:
      check:
        plan.toState(DeliveryState.Mix, trigger, {Guard.InMixGrace}) ==
          Opt.some(DeliveryState.NextRoundRetry)
        plan.toState(DeliveryState.Mix, trigger) == Opt.some(
          DeliveryState.NotPropagated
        )
    check:
      plan.toState(DeliveryState.Mix, Trigger.MixNotMounted, {Guard.InMixGrace}) ==
        Opt.some(DeliveryState.NotPropagated)
      plan.fixedToState(DeliveryState.Mix, Trigger.TooLargeForMix) ==
        Opt.some(DeliveryState.NotPropagated)
      plan.fixedToState(DeliveryState.Prove, Trigger.TooLargeForMix) ==
        Opt.some(DeliveryState.NotPropagated)

  test "Preferred hands the task to the plain path when mix cannot take it":
    let plan = planOf(AnonymityLevel.Preferred, AllTransports)
    for trigger in MixUnusableTriggers +
        {Trigger.TooLargeForMix, Trigger.MixWindowElapsed}:
      let handOver = plan.transition(DeliveryState.Mix, trigger).get()
      check:
        plan.fixedToState(DeliveryState.Mix, trigger) == Opt.some(DeliveryState.Relay)
        handOver.toState == DeliveryState.Relay
        handOver.effects == {TransitionEffect.ReportMixFallback}
    check plan.fixedToState(DeliveryState.Mix, Trigger.ServiceUnavailable) ==
      Opt.some(DeliveryState.NextRoundRetry)

  test "relay with no peers falls back to lightpush and fails without lightpush":
    let both = planOf(AnonymityLevel.None, PlainTransports)
    let relayOnly = planOf(AnonymityLevel.None, {DeliveryState.Relay}, resend = false)
    check:
      both.fixedToState(DeliveryState.Relay, Trigger.NoRelayPeers) ==
        Opt.some(DeliveryState.Lightpush)
      relayOnly.fixedToState(DeliveryState.Relay, Trigger.NoRelayPeers) ==
        Opt.some(DeliveryState.NotPropagated)

  test "a retry starts a new round and the end of the window fails the task":
    let plan = planOf(AnonymityLevel.None, PlainTransports)
    check:
      plan.toState(DeliveryState.NextRoundRetry, Trigger.RetryTick, {Guard.NeedsProof}) ==
        Opt.some(DeliveryState.Prove)
      plan.toState(DeliveryState.NextRoundRetry, Trigger.RetryTick) ==
        Opt.some(DeliveryState.Relay)
      plan.fixedToState(DeliveryState.Lightpush, Trigger.ServiceBusy) ==
        Opt.some(DeliveryState.NextRoundRetry)
      plan.fixedToState(DeliveryState.Relay, Trigger.WindowElapsed) ==
        Opt.some(DeliveryState.NotPropagated)
      plan.fixedToState(DeliveryState.NextRoundRetry, Trigger.WindowElapsed) ==
        Opt.some(DeliveryState.NotPropagated)
      plan.fixedToState(DeliveryState.Prove, Trigger.OverBudget) ==
        Opt.some(DeliveryState.NotPropagated)

  test "a restart starts a new round, or the Store wait again":
    let plan = planOf(AnonymityLevel.None, PlainTransports)
    check:
      plan.toState(DeliveryState.Lightpush, Trigger.Started, {Guard.NeedsProof}) ==
        Opt.some(DeliveryState.Prove)
      plan.toState(DeliveryState.Lightpush, Trigger.Started) ==
        Opt.some(DeliveryState.Relay)
      plan.fixedToState(DeliveryState.AwaitingStore, Trigger.Started) ==
        Opt.some(DeliveryState.AwaitingStore)
      plan.fixedToState(DeliveryState.StoreResend, Trigger.Started) ==
        Opt.some(DeliveryState.AwaitingStore)

  test "a rejected proof gets a new round only when the RLN backend can refresh it":
    let plan = planOf(AnonymityLevel.None, PlainTransports)
    let refreshed = plan
      .transition(
        DeliveryState.Lightpush, Trigger.ProofRejected, {Guard.CanRefreshProof}
      )
      .get()
    let failed = plan.transition(DeliveryState.Lightpush, Trigger.ProofRejected).get()
    check:
      refreshed.toState == DeliveryState.NextRoundRetry
      refreshed.effects == {TransitionEffect.RefreshProof}
      failed.toState == DeliveryState.NotPropagated
      failed.effects == {}

  test "a Store miss gives a resend while the task can get one":
    let plan = planOf(AnonymityLevel.None, PlainTransports)
    let noResend = planOf(AnonymityLevel.None, PlainTransports, resend = false)
    check:
      plan.toState(DeliveryState.AwaitingStore, Trigger.StoreMissed, {Guard.CanResend}) ==
        Opt.some(DeliveryState.StoreResend)
      plan.toState(DeliveryState.AwaitingStore, Trigger.StoreMissed) ==
        Opt.some(DeliveryState.AwaitingStore)
      noResend.toState(
        DeliveryState.AwaitingStore, Trigger.StoreMissed, {Guard.CanResend}
      ) == Opt.some(DeliveryState.AwaitingStore)
      not noResend.hasResend()
    for trigger in LightpushTriggers:
      check plan.fixedToState(DeliveryState.StoreResend, trigger) ==
        Opt.some(DeliveryState.AwaitingStore)
    check:
      plan.fixedToState(DeliveryState.StoreResend, Trigger.StoreReported) ==
        Opt.some(DeliveryState.Stored)
      plan.transition(DeliveryState.StoreResend, Trigger.StoreWindowElapsed) ==
        Opt.some(
          Transition(
            fromState: DeliveryState.StoreResend,
            triggers: {Trigger.StoreWindowElapsed},
            toState: DeliveryState.NotStored,
            effects: {TransitionEffect.ReportStoreTimeout},
          )
        )

  test "only a plain message of a reliable node waits for Store":
    let plan = planOf(AnonymityLevel.Preferred, AllTransports)
    let reliable = {Guard.Reliable}
    check:
      plan.toState(DeliveryState.Relay, Trigger.Published, reliable) ==
        Opt.some(DeliveryState.AwaitingStore)
      plan.toState(DeliveryState.Lightpush, Trigger.Published, reliable) ==
        Opt.some(DeliveryState.AwaitingStore)
      plan.toState(DeliveryState.Mix, Trigger.Published, reliable) ==
        Opt.some(DeliveryState.MixDelivered)
    for transport in AllTransports:
      check plan.toState(transport, Trigger.Published) ==
        Opt.some(DeliveryState.Propagated)
    check:
      plan.transition(DeliveryState.Mix, Trigger.Published).get().effects ==
        {TransitionEffect.ReportPropagatedOverMix}
      plan.transition(DeliveryState.Relay, Trigger.Published).get().effects ==
        {TransitionEffect.ReportPropagated}

  test "move takes the first transition whose guards hold, and runs its effects first":
    let plan = planOf(AnonymityLevel.None, PlainTransports)
    let published = StepReport.init(Trigger.Published)
    let reportable = plan.stepTriggers(DeliveryState.Relay)

    let reliable = PlanShell(facts: {Guard.Reliable})
    let waits = PlanTask(state: DeliveryState.Relay)
    check:
      plan.move(reliable, waits, DeliveryState.Relay, published, reportable).toState ==
        DeliveryState.AwaitingStore
      waits.state == DeliveryState.AwaitingStore
      waits.lastReport == Opt.some(published)
      # The effect of the transition runs before the effect of the new state.
      reliable.ran == @["ReportPropagated", "StartStoreWait"]

    let plain = PlanShell()
    let ends = PlanTask(state: DeliveryState.Relay)
    check:
      plan.move(plain, ends, DeliveryState.Relay, published, reportable).toState ==
        DeliveryState.Propagated
      plain.ran == @["ReportPropagated", "Finish"]

  test "a report that the step cannot give, or with no transition, goes to the shell":
    let plan = planOf(AnonymityLevel.None, PlainTransports)
    let shell = PlanShell()
    let task = PlanTask(state: DeliveryState.Relay)
    # The plan has a transition for `Published`, and the caller does not list it.
    check plan.firing(shell, task, DeliveryState.Relay, Trigger.Published, {}).toState ==
      DeliveryState.NotPropagated
    # `StoreReported` has no transition out of `Relay`.
    let report = StepReport.init(Trigger.StoreReported)
    check:
      plan.move(shell, task, DeliveryState.Relay, report, {Trigger.StoreReported}).toState ==
        DeliveryState.NotPropagated
      shell.unplanned ==
        @[
          (DeliveryState.Relay, Trigger.Published),
          (DeliveryState.Relay, Trigger.StoreReported),
        ]
      task.state == DeliveryState.NotPropagated
      shell.ran == @["ReportFailed", "Finish"]

  test "the plan of a node with relay and lightpush":
    check $planOf(AnonymityLevel.None, PlainTransports) == """
Initial -- Started[NeedsProof] --> Prove
Initial -- Started --> Relay
Prove -- Started[NeedsProof] --> Prove
Prove -- Started --> Relay
Prove -- Proved --> Relay
Prove -- {ProofNotReady, ProofTransient, StepRaised} --> NextRoundRetry
Prove -- {OverBudget, ProofPermanent, ProofBudgetExhausted} --> NotPropagated
Relay -- Started[NeedsProof] --> Prove
Relay -- Started --> Relay
Relay -- Published[Reliable] / {ReportPropagated} --> AwaitingStore
Relay -- Published / {ReportPropagated} --> Propagated
Relay -- ProofRejected[CanRefreshProof] / {RefreshProof} --> NextRoundRetry
Relay -- ProofRejected --> NotPropagated
Relay -- {Rejected, WindowElapsed} --> NotPropagated
Relay -- StepRaised --> NextRoundRetry
Relay -- {ZeroPeers, NoRelayPeers} --> Lightpush
Lightpush -- Started[NeedsProof] --> Prove
Lightpush -- Started --> Relay
Lightpush -- Published[Reliable] / {ReportPropagated} --> AwaitingStore
Lightpush -- Published / {ReportPropagated} --> Propagated
Lightpush -- ProofRejected[CanRefreshProof] / {RefreshProof} --> NextRoundRetry
Lightpush -- ProofRejected --> NotPropagated
Lightpush -- {Rejected, WindowElapsed} --> NotPropagated
Lightpush -- StepRaised --> NextRoundRetry
Lightpush -- {ZeroPeers, NoLightpushPeer, ServiceNoRelayPeers, ServiceBusy, ServiceUnavailable, ServiceError} --> NextRoundRetry
StoreResend -- Started --> AwaitingStore
StoreResend -- StoreReported --> Stored
StoreResend -- StoreWindowElapsed / {ReportStoreTimeout} --> NotStored
StoreResend -- {Published, ZeroPeers, NoLightpushPeer, ServiceNoRelayPeers, ServiceBusy, ServiceUnavailable, ServiceError, ProofRejected, Rejected, AttemptTimedOut, StepRaised} --> AwaitingStore
NextRoundRetry -- Started[NeedsProof] --> Prove
NextRoundRetry -- Started --> Relay
NextRoundRetry -- RetryTick[NeedsProof] --> Prove
NextRoundRetry -- RetryTick --> Relay
NextRoundRetry -- WindowElapsed --> NotPropagated
AwaitingStore -- Started --> AwaitingStore
AwaitingStore -- StoreReported --> Stored
AwaitingStore -- StoreWindowElapsed / {ReportStoreTimeout} --> NotStored
AwaitingStore -- StoreMissed[CanResend] --> StoreResend
AwaitingStore -- StoreMissed --> AwaitingStore
StoreResend entry / {StartStoreWait}
AwaitingStore entry / {StartStoreWait}
Stored entry / {ReportSent, Finish}
Propagated entry / {Finish}
NotStored entry / {ReportNotStored, Finish}
NotPropagated entry / {ReportFailed, Finish}"""

  test "the plan of a Preferred node":
    check $planOf(AnonymityLevel.Preferred, AllTransports) == """
Initial -- Started[NeedsProof] --> Prove
Initial -- Started --> Mix
Prove -- Started[NeedsProof] --> Prove
Prove -- Started --> Mix
Prove -- Proved --> Mix
Prove -- {ProofNotReady, ProofTransient, StepRaised} --> NextRoundRetry
Prove -- {OverBudget, ProofPermanent, ProofBudgetExhausted} --> NotPropagated
Relay -- Started[NeedsProof] --> Prove
Relay -- Started --> Mix
Relay -- Published[Reliable] / {ReportPropagated} --> AwaitingStore
Relay -- Published / {ReportPropagated} --> Propagated
Relay -- ProofRejected[CanRefreshProof] / {RefreshProof} --> NextRoundRetry
Relay -- ProofRejected --> NotPropagated
Relay -- {Rejected, WindowElapsed} --> NotPropagated
Relay -- StepRaised --> NextRoundRetry
Relay -- {ZeroPeers, NoRelayPeers} --> Lightpush
Lightpush -- Started[NeedsProof] --> Prove
Lightpush -- Started --> Mix
Lightpush -- Published[Reliable] / {ReportPropagated} --> AwaitingStore
Lightpush -- Published / {ReportPropagated} --> Propagated
Lightpush -- ProofRejected[CanRefreshProof] / {RefreshProof} --> NextRoundRetry
Lightpush -- ProofRejected --> NotPropagated
Lightpush -- {Rejected, WindowElapsed} --> NotPropagated
Lightpush -- StepRaised --> NextRoundRetry
Lightpush -- {ZeroPeers, NoLightpushPeer, ServiceNoRelayPeers, ServiceBusy, ServiceUnavailable, ServiceError} --> NextRoundRetry
Mix -- Started[NeedsProof] --> Prove
Mix -- Started --> Mix
Mix -- ProofRejected[CanRefreshProof] / {RefreshProof} --> NextRoundRetry
Mix -- ProofRejected --> NotPropagated
Mix -- {Rejected, WindowElapsed} --> NotPropagated
Mix -- StepRaised --> NextRoundRetry
Mix -- Published[Reliable] / {ReportPropagatedOverMix} --> MixDelivered
Mix -- Published / {ReportPropagatedOverMix} --> Propagated
Mix -- {ZeroPeers, ServiceNoRelayPeers, ServiceBusy, ServiceUnavailable, ServiceError} --> NextRoundRetry
Mix -- {TooLargeForMix, MixNotMounted, MixUnavailable, MixSelfHop, MixNoExit, MixWindowElapsed} / {ReportMixFallback} --> Relay
StoreResend -- Started --> AwaitingStore
StoreResend -- StoreReported --> Stored
StoreResend -- StoreWindowElapsed / {ReportStoreTimeout} --> NotStored
StoreResend -- {Published, ZeroPeers, NoLightpushPeer, ServiceNoRelayPeers, ServiceBusy, ServiceUnavailable, ServiceError, ProofRejected, Rejected, AttemptTimedOut, StepRaised} --> AwaitingStore
NextRoundRetry -- Started[NeedsProof] --> Prove
NextRoundRetry -- Started --> Mix
NextRoundRetry -- RetryTick[NeedsProof] --> Prove
NextRoundRetry -- RetryTick --> Mix
NextRoundRetry -- WindowElapsed --> NotPropagated
AwaitingStore -- Started --> AwaitingStore
AwaitingStore -- StoreReported --> Stored
AwaitingStore -- StoreWindowElapsed / {ReportStoreTimeout} --> NotStored
AwaitingStore -- StoreMissed[CanResend] --> StoreResend
AwaitingStore -- StoreMissed --> AwaitingStore
StoreResend entry / {StartStoreWait}
AwaitingStore entry / {StartStoreWait}
Stored entry / {ReportSent, Finish}
MixDelivered entry / {ReportSentOverMix, Finish}
Propagated entry / {Finish}
NotStored entry / {ReportNotStored, Finish}
NotPropagated entry / {ReportFailed, Finish}"""

  test "the plan of a Required node":
    check $planOf(AnonymityLevel.Required, {DeliveryState.Mix}) == """
Initial -- Started[NeedsProof] --> Prove
Initial -- Started --> Mix
Prove -- Started[NeedsProof] --> Prove
Prove -- Started --> Mix
Prove -- Proved --> Mix
Prove -- {ProofNotReady, ProofTransient, StepRaised} --> NextRoundRetry
Prove -- {OverBudget, ProofPermanent, ProofBudgetExhausted, ProofSizeUnknown, TooLargeForMix} --> NotPropagated
Mix -- Started[NeedsProof] --> Prove
Mix -- Started --> Mix
Mix -- ProofRejected[CanRefreshProof] / {RefreshProof} --> NextRoundRetry
Mix -- ProofRejected --> NotPropagated
Mix -- {Rejected, WindowElapsed} --> NotPropagated
Mix -- StepRaised --> NextRoundRetry
Mix -- Published[Reliable] / {ReportPropagatedOverMix} --> MixDelivered
Mix -- Published / {ReportPropagatedOverMix} --> Propagated
Mix -- {ZeroPeers, ServiceNoRelayPeers, ServiceBusy, ServiceUnavailable, ServiceError} --> NextRoundRetry
Mix -- {TooLargeForMix, MixNotMounted} --> NotPropagated
Mix -- {MixUnavailable, MixSelfHop, MixNoExit}[InMixGrace] --> NextRoundRetry
Mix -- {MixUnavailable, MixSelfHop, MixNoExit} --> NotPropagated
NextRoundRetry -- Started[NeedsProof] --> Prove
NextRoundRetry -- Started --> Mix
NextRoundRetry -- RetryTick[NeedsProof] --> Prove
NextRoundRetry -- RetryTick --> Mix
NextRoundRetry -- WindowElapsed --> NotPropagated
MixDelivered entry / {ReportSentOverMix, Finish}
Propagated entry / {Finish}
NotPropagated entry / {ReportFailed, Finish}"""
