## The state machine of a send.
## In each state a step runs, and the step reports a trigger.
## The trigger fires a transition, and the task moves to the to state of the transition.
## A transition can have guards and transition effects.
## A state can have state effects.
## The config builds the plan of the node, its list of transitions, at startup.

{.push raises: [].}

import std/[algorithm, sequtils, setutils, strutils], results
import logos_delivery/api/conf/modes

type
  DeliveryState* {.pure.} = enum
    Initial ## In the send queue, before `deliver` starts.
    Prove
      ## Attaches the RLN proof. `enqueue` took the charge of the first proof.
      ## A new proof after a rejection takes a new charge here.
    Relay
    Lightpush
    Mix
    StoreResend ## Lightpush again, after a Store node did not report the message.
    NextRoundRetry ## Waits for the next tick of the retry loop.
    AwaitingStore ## Waits for a Store node to report the message.
    Stored
    MixDelivered
    Propagated
    NotStored
    NotPropagated

  Trigger* {.pure.} = enum
    ## What a step reports.
    ## It fires a transition out of the state of the step.
    Unreported
      ## The zero value of a report.
      ## No transition has it, so a step that reports nothing fails the send.
    Started ## `deliver` starts or restarts the task.
    Proved
    OverBudget ## The epoch budget has no charge left for a new proof.
    ProofNotReady
    ProofTransient
    ProofPermanent
    ProofBudgetExhausted
    ProofSizeUnknown
    Published ## The publish reached at least one peer.
    ZeroPeers ## The publish worked and reached no peer.
    NoRelayPeers
    NoLightpushPeer
    ServiceNoRelayPeers ## The lightpush service has no relay peer.
    ServiceBusy
    ServiceUnavailable
    ServiceError
    ProofRejected
    Rejected ## A peer rejected the message for a reason that a retry cannot clear.
    AttemptTimedOut
    StepRaised
    TooLargeForMix
    MixNotMounted
    MixUnavailable
    MixSelfHop
    MixNoExit
    MixWindowElapsed
    RetryTick
    WindowElapsed
    StoreReported
    StoreMissed
    StoreWindowElapsed

  Guard* {.pure.} = enum
    ## A fact about the task.
    ## A transition with a guard fires only while the fact is true.
    NeedsProof ## The task needs an RLN proof, or a charge for a new one.
    Reliable ## P2P reliability is on and the message is not ephemeral.
    CanResend ## The task can get one more resend.
    InMixGrace ## The task is within `MixUnusableGrace` of its admission.
    CanRefreshProof
      ## The RLN backend can refresh its proofs, and the task can get one more new proof.

  TransitionEffect* {.pure.} = enum
    ## A side effect that triggers when a task moves along a transition.
    ReportPropagated
      ## Records the first propagation and emits `MessagePropagatedEvent` once.
    ReportPropagatedOverMix
      ## `ReportPropagated` for a message that went out over mix.
      ## It marks the task, so the send service never asks Store about it.
    ReportMixFallback ## Logs the hand-over from mix to the plain path.
    ReportStoreTimeout ## Logs the end of the Store validation window and counts it.
    RefreshProof
      ## Tells the RLN backend about the rejection.
      ## Clears the proof and the charge, so the next round gets a new proof.

  StateEffect* {.pure.} = enum
    ## A side effect that triggers when a task enters a state.
    ## The effects of a state run in the sequence of this enum.
    StartStoreWait ## Opens the Store wait, if it is not open.
    ReportSent ## Emits `MessageSentEvent`.
    ReportSentOverMix ## Emits `MessageSentEvent` for the reply of the mix exit.
    ReportNotStored ## Emits `MessageErrorEvent`.
    ReportFailed ## Logs the failed send at ERROR and emits `MessageErrorEvent`.
    Finish
      ## Ends the Store wait and takes the task out of the send queue.
      ## Keep it last, so each other effect of a final state runs before it.

  StepReport* = object
    trigger*: Trigger
    desc*: string
      ## Text from a remote node or a library, for the log lines and the error text.

  Transition* = object
    ## A directed link (an arrow) between two states, the from state and the to state.
    ## Each of its triggers fires it, while each of its guards holds.
    fromState*: DeliveryState
    triggers*: set[Trigger]
    guards*: set[Guard]
    toState*: DeliveryState
    effects*: set[TransitionEffect]

  DeliveryPlan* = object
    level*: AnonymityLevel
    chain*: seq[DeliveryState] ## The transports, in the order that a round tries them.
    transitions*: seq[Transition]
      ## The first transition that fires wins, so a guarded transition comes first.
      ## `buildDeliveryPlan` sorts the transitions by from state with a stable sort,
      ## so the print has the transitions of one state together.
      ## The sort keeps the sequence of the transitions of each state.

static:
  doAssert StateEffect.high == StateEffect.Finish

const
  RoundStates* = {Prove, Relay, Lightpush, Mix}
    ## The states of one round, which ends at a wait or a final state.
  StoreWaitStates* = {AwaitingStore, StoreResend}
    ## The states that wait for a Store answer.
  FinalStates* = {Stored, MixDelivered, Propagated, NotStored, NotPropagated}

  RetryableServiceTriggers =
    {ZeroPeers, ServiceNoRelayPeers, ServiceBusy, ServiceUnavailable, ServiceError}
    ## No lightpush service could take the message now.
  MixUnusableTriggers* = {MixNotMounted, MixUnavailable, MixSelfHop, MixNoExit}
  LightpushTriggers* =
    RetryableServiceTriggers + {Published, ProofRejected, Rejected, StepRaised}
    ## The triggers of a lightpush attempt, also the attempt of a resend.
  StoreResendTriggers = LightpushTriggers + {NoLightpushPeer, AttemptTimedOut}
    ## The check of the lightpush peer before a resend gives `NoLightpushPeer`.
  ProveFailures = {OverBudget, ProofPermanent, ProofBudgetExhausted}
    ## The triggers of the proof step that fail the send.
  SizeCheckFailures = {ProofSizeUnknown, TooLargeForMix}
    ## A `Required` node checks the size of the message for mix before the admission.
  ProveTriggers = ProveFailures + {Proved, ProofNotReady, ProofTransient, StepRaised}
  RelayTriggers = {
    Published, ZeroPeers, NoRelayPeers, ProofRejected, Rejected, StepRaised,
    WindowElapsed,
  }
  MixTriggers =
    LightpushTriggers + MixUnusableTriggers + {TooLargeForMix, WindowElapsed}
  NonFailureTriggers = {
    Started, Proved, Published, RetryTick, WindowElapsed, StoreReported, StoreMissed,
    StoreWindowElapsed,
  } ## The triggers that do not tell why an attempt failed.

func init*(T: type StepReport, trigger: Trigger, desc = ""): T =
  T(trigger: trigger, desc: desc)

func isFinal*(state: DeliveryState): bool =
  state in FinalStates

func isFailure*(trigger: Trigger): bool =
  ## True when `trigger` tells why an attempt failed.
  trigger notin NonFailureTriggers

func stateEffects*(state: DeliveryState): set[StateEffect] =
  ## Each final state finishes the task.
  case state
  of StoreWaitStates:
    {StartStoreWait}
  of Stored:
    {ReportSent, Finish}
  of MixDelivered:
    {ReportSentOverMix, Finish}
  of Propagated:
    {Finish}
  of NotStored:
    {ReportNotStored, Finish}
  of NotPropagated:
    {ReportFailed, Finish}
  of Initial, Prove, Relay, Lightpush, Mix, NextRoundRetry:
    {}

type
  Label = object ## The label of a transition, `Triggers[Guard] / {Effects}`.
    triggers: set[Trigger]
    guards: set[Guard]
    effects: set[TransitionEffect]

  Source = object ## The from states and the label of `From -- Label`.
    fromStates: set[DeliveryState]
    label: Label

# These operators write a transition in the notation of UML,
# `From -- Triggers[Guard] / {Effects} --> To`.
# `$` prints a transition in the same notation, so a printed line is an arrow of this file.
# A set of from states on the left gives the transition of the arrow out of each state.
# Put a transition with a guard before the transition with the same trigger and no guard.
# `Triggers[A, B]` gives a transition two guards, and it fires while the two hold.
# `-->` binds less tightly than each other operator, and `/` binds more tightly than `--`.
# `--` binds as `+` and `-` do, so put set arithmetic in parentheses.
# Use `arrows.add`, as `arrows &= a -- t --> b` parses as `(arrows &= a -- t) --> b`.

func label(triggers: set[Trigger]): Label =
  Label(triggers: triggers)

func label(trigger: Trigger): Label =
  Label(triggers: {trigger})

func label(it: Label): Label =
  it

func `[]`(triggers: Trigger | set[Trigger], guards: varargs[Guard]): Label =
  var guarded = label(triggers)
  for guard in guards:
    guarded.guards.incl(guard)
  guarded

func `/`(it: Trigger | set[Trigger] | Label, effects: set[TransitionEffect]): Label =
  var labelled = label(it)
  labelled.effects = effects
  labelled

func `--`(fromStates: set[DeliveryState], it: Trigger | set[Trigger] | Label): Source =
  Source(fromStates: fromStates, label: label(it))

func `--`(fromState: DeliveryState, it: Trigger | set[Trigger] | Label): Source =
  {fromState} -- it

func `-->`(source: Source, toState: DeliveryState): seq[Transition] =
  var arrows: seq[Transition]
  for fromState in source.fromStates:
    arrows.add Transition(
      fromState: fromState,
      triggers: source.label.triggers,
      guards: source.label.guards,
      toState: toState,
      effects: source.label.effects,
    )
  arrows

func chainOf(
    level: AnonymityLevel, transports: set[DeliveryState]
): Result[seq[DeliveryState], string] =
  var chain: seq[DeliveryState]
  if level != AnonymityLevel.None:
    if Mix notin transports:
      return err("The " & $level & " anonymity level needs mix")
    chain.add(Mix)
  if level != AnonymityLevel.Required:
    chain.add([Relay, Lightpush].filterIt(it in transports))
  if level == AnonymityLevel.Preferred and chain.len == 1:
    return err("The Preferred anonymity level needs relay or lightpush")
  if chain.len == 0:
    return err("No valid send processor found for the delivery task")
  ok(chain)

func buildDeliveryPlan*(
    level: AnonymityLevel, transports: set[DeliveryState], resend: bool
): Result[DeliveryPlan, string] =
  ## Builds the plan of `level` for the mounted `transports`.
  ## With `resend`, a message that Store does not report goes out again over lightpush.
  let chain = ?chainOf(level, transports)
  let used = chain.toSet()
  let plain = used - {Mix}
  # Only a plain publish waits for Store. `resend` tells if the node has a resender.
  let hasResend = resend and plain != {}
  let starts = {Initial, Prove, NextRoundRetry} + used
  var arrows: seq[Transition]

  arrows.add starts -- Started[NeedsProof] --> Prove
  arrows.add starts -- Started --> chain[0]
  arrows.add Prove -- Proved --> chain[0]
  arrows.add Prove -- {ProofNotReady, ProofTransient, StepRaised} --> NextRoundRetry
  if level == AnonymityLevel.Required:
    arrows.add Prove -- (ProveFailures + SizeCheckFailures) --> NotPropagated
  else:
    arrows.add Prove -- ProveFailures --> NotPropagated

  arrows.add plain -- Published[Reliable] / {ReportPropagated} --> AwaitingStore
  arrows.add plain -- Published / {ReportPropagated} --> Propagated
  arrows.add used -- ProofRejected[CanRefreshProof] / {RefreshProof} --> NextRoundRetry
  arrows.add used -- ProofRejected --> NotPropagated
  arrows.add used -- {Rejected, WindowElapsed} --> NotPropagated
  arrows.add used -- StepRaised --> NextRoundRetry
  if Relay in used:
    arrows.add Relay -- {ZeroPeers, NoRelayPeers} -->
      (if Lightpush in used: Lightpush else: NotPropagated)
  if Lightpush in used:
    arrows.add Lightpush -- (RetryableServiceTriggers + {NoLightpushPeer}) -->
      NextRoundRetry
  if Mix in used:
    arrows.add Mix -- Published[Reliable] / {ReportPropagatedOverMix} --> MixDelivered
    arrows.add Mix -- Published / {ReportPropagatedOverMix} --> Propagated
    arrows.add Mix -- RetryableServiceTriggers --> NextRoundRetry
    if level == AnonymityLevel.Preferred:
      arrows.add Mix --
        (MixUnusableTriggers + {TooLargeForMix, MixWindowElapsed}) / {ReportMixFallback} -->
        chain[1]
    else:
      arrows.add Mix -- {TooLargeForMix, MixNotMounted} --> NotPropagated
      arrows.add Mix -- (MixUnusableTriggers - {MixNotMounted})[InMixGrace] -->
        NextRoundRetry
      arrows.add Mix -- (MixUnusableTriggers - {MixNotMounted}) --> NotPropagated

  arrows.add NextRoundRetry -- RetryTick[NeedsProof] --> Prove
  arrows.add NextRoundRetry -- RetryTick --> chain[0]
  arrows.add NextRoundRetry -- WindowElapsed --> NotPropagated
  if plain != {}:
    let waits =
      if hasResend:
        StoreWaitStates
      else:
        {AwaitingStore}
    arrows.add waits -- Started --> AwaitingStore
    arrows.add waits -- StoreReported --> Stored
    arrows.add waits -- StoreWindowElapsed / {ReportStoreTimeout} --> NotStored
    if hasResend:
      arrows.add AwaitingStore -- StoreMissed[CanResend] --> StoreResend
      arrows.add StoreResend -- StoreResendTriggers --> AwaitingStore
    arrows.add AwaitingStore -- StoreMissed --> AwaitingStore
  ok(
    DeliveryPlan(
      level: level, chain: chain, transitions: arrows.sortedByIt(it.fromState)
    )
  )

func stepTriggers*(plan: DeliveryPlan, state: DeliveryState): set[Trigger] =
  ## The triggers that the step of `state` can report in `plan`.
  case state
  of Prove:
    if plan.level == AnonymityLevel.Required:
      ProveTriggers + SizeCheckFailures
    else:
      ProveTriggers
  of Relay:
    RelayTriggers
  of Lightpush:
    LightpushTriggers + {NoLightpushPeer, WindowElapsed}
  of Mix:
    if plan.level == AnonymityLevel.Preferred:
      MixTriggers + {MixWindowElapsed}
    else:
      MixTriggers
  of StoreResend:
    StoreResendTriggers + {StoreReported, StoreWindowElapsed}
  of NextRoundRetry:
    {RetryTick, WindowElapsed}
  of AwaitingStore:
    {StoreReported, StoreMissed, StoreWindowElapsed}
  of Initial, FinalStates:
    {}

func guards*(
    plan: DeliveryPlan, fromState: DeliveryState, trigger: Trigger
): set[Guard] =
  ## The guards of the transitions that `trigger` can fire out of `fromState`.
  var guards: set[Guard]
  for arrow in plan.transitions:
    if arrow.fromState == fromState and trigger in arrow.triggers:
      guards = guards + arrow.guards
  guards

func transition*(
    plan: DeliveryPlan,
    fromState: DeliveryState,
    trigger: Trigger,
    facts: set[Guard] = {},
): Opt[Transition] =
  ## The first transition out of `fromState` that `trigger` fires while `facts` hold.
  for arrow in plan.transitions:
    if arrow.fromState == fromState and trigger in arrow.triggers and
        arrow.guards <= facts:
      return Opt.some(arrow)
  Opt.none(Transition)

proc firing*[Shell, Task](
    plan: DeliveryPlan,
    shell: Shell,
    task: Task,
    fromState: DeliveryState,
    trigger: Trigger,
    reportable: set[Trigger],
): Transition =
  ## The transition that `trigger` fires out of `fromState` for `task`.
  ## `reportable` holds the triggers that the caller can report.
  ## A step gives the `stepTriggers` of its state, and `deliver` gives `Started`.
  ## `shell.holds(task, guard)` tells if each guard of the candidates holds.
  ## Another trigger, or a trigger with no transition, goes to the state of `unplanned`.
  mixin holds, unplanned
  if trigger in reportable:
    var facts: set[Guard]
    for guard in plan.guards(fromState, trigger):
      if shell.holds(task, guard):
        facts.incl(guard)
    let planned = plan.transition(fromState, trigger, facts)
    if planned.isSome():
      return planned.get()
  return Transition(
    fromState: fromState,
    triggers: {trigger},
    toState: shell.unplanned(task, fromState, trigger),
  )

proc move*[Shell, Task](
    plan: DeliveryPlan,
    shell: Shell,
    task: Task,
    fromState: DeliveryState,
    report: StepReport,
    reportable: set[Trigger],
): Transition =
  ## Moves `task` along the transition that `report` fires, and returns the transition.
  ## `reportable` is as in `firing`.
  ## The task records the report and its new state.
  ## Then the transition effects run, and then the state effects of the to state.
  ## The effects of one set run in the sequence of their enum values.
  ## `shell.runEffect(task, effect, report)` runs each effect.
  ## A move to the same state enters it again, and its state effects run again.
  ## A restart uses this.
  ## The stop closes the Store wait, and `Started` opens it again.
  ## No effect waits for a future, so no other task runs during a move.
  ## A listener of an event that an effect emits runs inside the move.
  ## It sees the task as the earlier effects left it.
  mixin runEffect
  let taken = plan.firing(shell, task, fromState, report.trigger, reportable)
  task.lastReport = Opt.some(report)
  task.state = taken.toState
  for effect in taken.effects:
    shell.runEffect(task, effect, report)
  for effect in stateEffects(taken.toState):
    shell.runEffect(task, effect, report)
  return taken

func braced[T](values: set[T]): string =
  "{" & toSeq(values).join(", ") & "}"

func `$`*(transition: Transition): string =
  ## The notation of the arrows of `buildDeliveryPlan`,
  ## `From -- Triggers[Guard] / {Effects} --> To`.
  var label =
    if transition.triggers.card == 1:
      $toSeq(transition.triggers)[0]
    else:
      braced(transition.triggers)
  if transition.guards != {}:
    label &= "[" & toSeq(transition.guards).join(", ") & "]"
  if transition.effects != {}:
    label &= " / " & braced(transition.effects)
  $transition.fromState & " -- " & label & " --> " & $transition.toState

func `$`*(plan: DeliveryPlan): string =
  ## One line for each transition.
  ## Then one line for each state of the plan that has state effects.
  var lines = plan.transitions.mapIt($it)
  var states: set[DeliveryState]
  for transition in plan.transitions:
    states = states + {transition.fromState, transition.toState}
  for state in DeliveryState:
    if state in states and stateEffects(state) != {}:
      lines.add($state & " entry / " & braced(stateEffects(state)))
  lines.join("\n")
