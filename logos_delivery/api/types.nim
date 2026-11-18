{.push raises: [].}

import libp2p/crypto/crypto, chronos, results
import stew/byteutils
import logos_delivery/waku/utils/requests as request_utils
import
  logos_delivery/waku/waku_core/
    [topics/content_topic, message/message, message/digest, time]

export content_topic, message, digest

type
  MessageEnvelope* = object
    contentTopic*: ContentTopic
    payload*: seq[byte]
    ephemeral*: bool
    meta*: seq[byte]
      ## Opaque wire-format marker carried on the underlying WakuMessage.
      ## Higher layers (e.g. Reliable Channel) stamp this so peers can route
      ## ingress traffic to their corresponding layer. Empty by default.

  RequestId* = distinct string ## Identifies one send of a reliable channel.

  SendErrorKind* {.pure.} = enum
    NotStarted ## The messaging client does not run.
    NoShard ## The node finds no shard for the content topic of the message.
    TooLarge
      ## The message is above the size limit of the node, or above the size of
      ## one mix message at the `Required` anonymity level.
    RateLimited ## The rate-limit budget of the epoch does not admit the message.
    Duplicate ## The node already sends a message with this hash.
    QueueFull ## The node has `MaxSendsInFlight` sends with no last event.
    Other ## A fault with no kind of its own.

  SendError* = object
    kind*: SendErrorKind
    retryAfter*: Duration
      ## For `RateLimited`, the time until the budget of the epoch refills.
    desc*: string

  SendResult* = Result[WakuMessageHash, SendError]

  MessageErrorKind* {.pure.} = enum
    ## Why a send that `send` accepted failed.
    NotPropagated
      ## The node knows of no propagation of the message. A mix exit or a
      ## lightpush service can still have published it, when its answer did not come.
    NotStored
      ## The message propagated, and no Store node reported it inside the Store
      ## validation window.

  ConnectionStatus* {.pure.} = enum
    Disconnected
    PartiallyConnected
    Connected

  MessageSource* {.pure.} = enum
    Live = "live" ## delivered as it was published, over relay or filter
    History = "history" ## recovered from a Store peer, at start or after a gap

  PeerConnInfo* = object ## structured connected-peer info for the api boundary
    peerId*: string
    protocols*: seq[string]
    addresses*: seq[string]

proc new*(T: typedesc[RequestId], rng: crypto.Rng): T =
  ## Generate a new RequestId using the provided RNG.
  RequestId(request_utils.generateRequestId(rng))

proc `$`*(r: RequestId): string {.inline.} =
  string(r)

proc `==`*(a, b: RequestId): bool {.inline.} =
  string(a) == string(b)

func init*(
    T: type SendError,
    kind: SendErrorKind,
    desc: string,
    retryAfter: Duration = ZeroDuration,
): T =
  SendError(kind: kind, retryAfter: retryAfter, desc: desc)

func `$`*(error: SendError): string =
  ## The description, then the kind in parentheses. An `Other` error gives only
  ## its description. The kind comes last, so code that reads the start of a
  ## text still finds it.
  if error.kind == SendErrorKind.Other:
    return error.desc
  return error.desc & " (" & $error.kind & ")"

proc init*(
    T: type MessageEnvelope,
    contentTopic: ContentTopic,
    payload: seq[byte] | string,
    ephemeral: bool = false,
    meta: seq[byte] = @[],
): MessageEnvelope =
  when payload is seq[byte]:
    MessageEnvelope(
      contentTopic: contentTopic, payload: payload, ephemeral: ephemeral, meta: meta
    )
  else:
    MessageEnvelope(
      contentTopic: contentTopic,
      payload: payload.toBytes(),
      ephemeral: ephemeral,
      meta: meta,
    )

proc toWakuMessage*(envelope: MessageEnvelope): WakuMessage =
  ## Convert a MessageEnvelope to a WakuMessage.
  var wm = WakuMessage(
    contentTopic: envelope.contentTopic,
    payload: envelope.payload,
    ephemeral: envelope.ephemeral,
    meta: envelope.meta,
    timestamp: getNowInNanosecondTime(),
  )

  ## The send path (attachRlnProof) attaches the proof; its epoch derives from this timestamp.
  return wm

{.pop.}
