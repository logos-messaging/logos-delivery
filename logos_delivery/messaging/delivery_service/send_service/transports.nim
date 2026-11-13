## The transports of a message: relay, lightpush and mix.
## Each transport makes one attempt of a message and says how the attempt ended.
## The send service decides which transport gets a message, and when.

import chronicles, chronos, results
import logos_delivery/api/types
import
  logos_delivery/waku/[waku_core, waku],
  logos_delivery/waku/api/publish,
  logos_delivery/waku/waku_lightpush/[common, rpc],
  logos_delivery/waku/waku_mix,
  logos_delivery/waku/node/peer_manager

{.push raises: [].}

logScope:
  topics = "send service transports"

const MixNotMountedReason* = "mix is not mounted"

const MixUnavailableReason* =
  "mix knows fewer than " & $MinMixPoolSize & " usable mix nodes"
  ## The pool counts only members with an address that mix routes.

const MixSelfHopReason* = "this node has no address that mix can use for replies"
  ## An IPv6-only or name-only announcement, or a NAT mapping not yet arrived.

const MixNoExitReason* = "no mix node serves lightpush on the shard of the message"

const MixTooLargeReason* = "message too large for mix"
  ## One mix message carries much less than the plain path.

type
  Transport* {.pure.} = enum
    Relay
    Lightpush
    Mix

  AttemptOutcome* {.pure.} = enum
    Propagated
    NotPropagated ## A later attempt of the same message can propagate.
    Invalid ## A repeat of this attempt cannot propagate the message.

  AttemptResult* = object
    outcome*: AttemptOutcome
    desc*: string
      ## Empty when the transport has no reason to give, as for an attempt with no peer.
    proofRefused*: bool
      ## A node refused the RLN proof of the message.
      ## Another attempt needs a new proof.
    validated*: bool
      ## The relay of this node validated the message, and the publish reached no peer.

  AttemptProc* = proc(
    pubsubTopic: PubsubTopic,
    msg: WakuMessage,
    peers: seq[RemotePeerInfo],
    validated: bool,
  ): Future[AttemptResult] {.async: (raises: [CancelledError]), gcsafe.}
    ## Makes one attempt of `msg`.
    ## A lightpush attempt uses the first of `peers`, and selects a peer when `peers` is empty.
    ## `validated` is true when the relay of this node validated `msg` in an earlier
    ## attempt. The relay transport then publishes with no validation, because the
    ## RLN validator refuses a proof that it already has.

  CheckBeforeAttemptProc* = proc(
    pubsubTopic: PubsubTopic, msg: WakuMessage
  ): Opt[AttemptResult] {.gcsafe, raises: [].}
    ## The result of an attempt that the transport can give with no network call.
    ## None when the transport can attempt `msg` now.

  TransportApi* = object
    attempt*: AttemptProc
    checkBeforeAttempt*: CheckBeforeAttemptProc

  Transports* = array[Transport, Opt[TransportApi]]
    ## None for a transport that this node does not have.

  MixUnusable* {.pure.} = enum
    None
    NotMounted
    Unavailable
    SelfHop
    NoExit

  MixState* = ref object
    unusable*: MixUnusable
      ## Why mix could not attempt the last message. `None` while mix can attempt one.

func propagated*(T: type AttemptResult): T =
  return T(outcome: AttemptOutcome.Propagated)

func notPropagated*(T: type AttemptResult, desc = ""): T =
  return T(outcome: AttemptOutcome.NotPropagated, desc: desc)

func invalid*(T: type AttemptResult, desc: string): T =
  return T(outcome: AttemptOutcome.Invalid, desc: desc)

func reason*(unusable: MixUnusable): string =
  case unusable
  of MixUnusable.None: ""
  of MixUnusable.NotMounted: MixNotMountedReason
  of MixUnusable.Unavailable: MixUnavailableReason
  of MixUnusable.SelfHop: MixSelfHopReason
  of MixUnusable.NoExit: MixNoExitReason

func mixTooLargeDesc*(size, limit: int): string =
  return
    MixTooLargeReason & ": the request has " & $size & " bytes, the limit is " & $limit &
    " bytes"

func isAlreadySeen(error: ErrorStatus): bool =
  return
    error.code == LightPushErrorCode.INVALID_MESSAGE and
    error.desc.get("") == AlreadySeenMessageDesc

func sendErrorDesc(error: ErrorStatus): string =
  return error.desc.get($error.code)

func reachedNoPeer(res: WakuLightPushResult): bool =
  return
    if res.isOk():
      res.get() == 0
    else:
      res.error.code == LightPushErrorCode.NO_PEERS_TO_RELAY

proc toAttemptResult(res: WakuLightPushResult): AttemptResult =
  let published = res.valueOr:
    if error.isRlnRejection():
      return AttemptResult(
        outcome: AttemptOutcome.NotPropagated,
        desc: error.sendErrorDesc(),
        proofRefused: true,
      )
    if error.isAlreadySeen():
      # The relay of this node, or of the lightpush service node, has the message.
      return AttemptResult.propagated()
    case error.code
    of LightPushErrorCode.NO_PEERS_TO_RELAY, LightPushErrorCode.TOO_MANY_REQUESTS,
        LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        LightPushErrorCode.INTERNAL_SERVER_ERROR:
      return AttemptResult.notPropagated()
    else:
      return AttemptResult.invalid(error.sendErrorDesc())
  if published == 0:
    return AttemptResult.notPropagated()
  return AttemptResult.propagated()

proc mixUnusable*(waku: Waku, pubsubTopic: PubsubTopic): MixUnusable =
  ## Why mix cannot attempt a message of `pubsubTopic` now, with no network call.
  ## It splits `mixReady()` into the mount, the self hop and the pool, then checks
  ## the exit with `selectMixLightpushPeer`, as `lightpushPublishToAny(mixify = true)` does.
  if not waku.mixMounted():
    return MixUnusable.NotMounted
  if not waku.mixReady():
    if not waku.mixSelfHopUsable():
      return MixUnusable.SelfHop
    return MixUnusable.Unavailable
  if waku.selectMixLightpushPeer(pubsubTopic).isNone():
    return MixUnusable.NoExit
  return MixUnusable.None

proc relayTransport*(waku: Waku): TransportApi =
  let publish = waku.relayPushHandler()
  return TransportApi(
    attempt: proc(
        pubsubTopic: PubsubTopic,
        msg: WakuMessage,
        peers: seq[RemotePeerInfo],
        validated: bool,
    ): Future[AttemptResult] {.async: (raises: [CancelledError]), gcsafe.} =
      try:
        let res =
          if validated:
            await waku.relayRepublish(pubsubTopic, msg)
          else:
            await publish(pubsubTopic, msg)
        var attemptResult = toAttemptResult(res)
        # The publish comes after the validation, so a publish to no peer shows
        # that the validation passed.
        attemptResult.validated = res.reachedNoPeer()
        return attemptResult
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        return AttemptResult.notPropagated("Exception in the relay publish: " & exc.msg),
    checkBeforeAttempt: proc(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ): Opt[AttemptResult] {.gcsafe, raises: [].} =
      # A relay with no peer still gives the message to the Store and the filter
      # clients of this node, so each attempt publishes.
      return Opt.none(AttemptResult),
  )

proc lightpushTransport*(waku: Waku): TransportApi =
  return TransportApi(
    attempt: proc(
        pubsubTopic: PubsubTopic,
        msg: WakuMessage,
        peers: seq[RemotePeerInfo],
        validated: bool,
    ): Future[AttemptResult] {.async: (raises: [CancelledError]), gcsafe.} =
      try:
        let res =
          if peers.len > 0:
            await waku.lightpushPublishTo(pubsubTopic, msg, peers[0])
          else:
            await waku.lightpushPublishToAny(pubsubTopic, msg)
        return toAttemptResult(res)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        return
          AttemptResult.notPropagated("Exception in the lightpush request: " & exc.msg),
    checkBeforeAttempt: proc(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ): Opt[AttemptResult] {.gcsafe, raises: [].} =
      if waku.lightpushPeerAvailable(pubsubTopic):
        return Opt.none(AttemptResult)
      return Opt.some(AttemptResult.notPropagated()),
  )

proc mixTransport*(waku: Waku, state = MixState()): TransportApi =
  ## INFO logs each change of `state.unusable`.
  return TransportApi(
    attempt: proc(
        pubsubTopic: PubsubTopic,
        msg: WakuMessage,
        peers: seq[RemotePeerInfo],
        validated: bool,
    ): Future[AttemptResult] {.async: (raises: [CancelledError]), gcsafe.} =
      try:
        return toAttemptResult(
          await waku.lightpushPublishToAny(pubsubTopic, msg, mixify = true)
        )
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        return AttemptResult.notPropagated("Exception in the mix send: " & exc.msg),
    checkBeforeAttempt: proc(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ): Opt[AttemptResult] {.gcsafe, raises: [].} =
      let (size, limit) = waku.mixLightpushSize(pubsubTopic, msg)
      if size > limit:
        return Opt.some(AttemptResult.invalid(mixTooLargeDesc(size, limit)))
      let unusable = waku.mixUnusable(pubsubTopic)
      if unusable != state.unusable:
        state.unusable = unusable
        if unusable == MixUnusable.None:
          info "Mix can carry messages again"
        else:
          info "Mix cannot carry messages", reason = unusable.reason()
      case unusable
      of MixUnusable.None:
        return Opt.none(AttemptResult)
      of MixUnusable.NotMounted:
        # A node mounts mix only at its start.
        return Opt.some(AttemptResult.invalid(unusable.reason()))
      of MixUnusable.Unavailable, MixUnusable.SelfHop, MixUnusable.NoExit:
        return Opt.some(AttemptResult.notPropagated(unusable.reason())),
  )

proc init*(T: type Transports, waku: Waku): T =
  var transports: Transports
  if waku.hasRelay():
    transports[Transport.Relay] = Opt.some(relayTransport(waku))
  if waku.hasLightpush():
    transports[Transport.Lightpush] = Opt.some(lightpushTransport(waku))
    # A mix send is a lightpush request through the mixnet.
    transports[Transport.Mix] = Opt.some(mixTransport(waku))
  return transports

{.pop.}
