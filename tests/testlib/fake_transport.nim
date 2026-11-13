import std/tables
import chronos, results, stew/byteutils
import
  logos_delivery/api/types,
  logos_delivery/waku/waku_core,
  logos_delivery/messaging/delivery_service/send_service/transports
import ./futures

type FakeTransport* = ref object
  ## A transport of the send service that a test scripts.
  ## The id of a message is its payload.
  checkResult*: Opt[AttemptResult] ## The result of `checkBeforeAttempt`.
  results*: seq[AttemptResult]
    ## The result of each attempt, in order. The last one repeats.
    ## With no result, each attempt propagates.
  stalled*: seq[string] ## The ids whose attempts wait for `release`.
  checks*: int
  calls*: seq[string] ## The id of each attempt, in order.
  messages*: seq[WakuMessage] ## The message of each attempt.
  peers*: seq[seq[RemotePeerInfo]] ## The peers of each attempt.
  validated*: seq[bool] ## The `validated` argument of each attempt.
  times*: seq[Moment] ## The start of each attempt.
  running*: int
  cancelled*: seq[string]
  attempts*: EventCounter ## Counts the attempts, so a test can wait for one.
  started: Table[string, AsyncEvent]
  stalls: Table[string, Future[void].Raising([CancelledError])]

proc new*(
    T: type FakeTransport,
    results: seq[AttemptResult] = @[],
    stalled: seq[string] = @[],
    checkResult = Opt.none(AttemptResult),
): T =
  return T(
    results: results,
    stalled: stalled,
    checkResult: checkResult,
    attempts: EventCounter(),
  )

proc id*(msg: WakuMessage): string =
  return string.fromBytes(msg.payload)

proc startedEvent(self: FakeTransport, id: string): AsyncEvent =
  if id notin self.started:
    self.started[id] = newAsyncEvent()
  return self.started.getOrDefault(id)

proc attemptStarted*(self: FakeTransport, id: string): Future[void] =
  ## Completes when an attempt of `id` starts. Each call returns a new future.
  return self.startedEvent(id).wait()

proc reply*(self: FakeTransport, id: string) =
  ## Lets the stalled attempt of `id` give its result.
  let stall = self.stalls.getOrDefault(id)
  if not stall.isNil() and not stall.finished():
    stall.complete()

proc nextResult(self: FakeTransport): AttemptResult =
  if self.results.len == 0:
    return AttemptResult.propagated()
  return self.results[min(self.calls.len, self.results.len) - 1]

proc api*(self: FakeTransport): TransportApi =
  return TransportApi(
    attempt: proc(
        pubsubTopic: PubsubTopic,
        msg: WakuMessage,
        peers: seq[RemotePeerInfo],
        validated: bool,
    ): Future[AttemptResult] {.async: (raises: [CancelledError]), gcsafe.} =
      let id = msg.id
      self.calls.add(id)
      self.messages.add(msg)
      self.peers.add(peers)
      self.validated.add(validated)
      self.times.add(Moment.now())
      self.attempts.inc()
      let res = self.nextResult()
      inc self.running
      defer:
        dec self.running
      self.startedEvent(id).fire()
      if id in self.stalled:
        let stall = Future[void].Raising([CancelledError]).init("fake-transport-stall")
        self.stalls[id] = stall
        try:
          await stall
        except CancelledError as exc:
          self.cancelled.add(id)
          raise exc
      else:
        # Suspend, so the attempts of two messages overlap.
        await sleepAsync(ZeroDuration)
      return res,
    checkBeforeAttempt: proc(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ): Opt[AttemptResult] {.gcsafe, raises: [].} =
      inc self.checks
      return self.checkResult,
  )

proc transportsOf*(pairs: varargs[(Transport, FakeTransport)]): Transports =
  var transports: Transports
  for (transport, fake) in pairs:
    transports[transport] = Opt.some(fake.api())
  return transports
