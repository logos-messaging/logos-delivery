{.push raises: [].}

import libp2p/crypto/crypto, chronos
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

  RequestId* = distinct string

  SendErrorKind* {.pure.} = enum
    ## Why `send` refused a message. A refused message gets no event.
    NotStarted ## The messaging client is not started.
    NotConnected
      ## The node has no connected peer and knows no lightpush peer for the shard
      ## of the message.
    NoShard ## The content topic maps to no shard of this node.
    Duplicate ## A message with the same hash is still in flight.
    QueueFull ## The node has its maximum of 200 sends with no last event.
    RateLimited ## The rate-limit budget of the epoch is spent, see `retryAfter`.
    TooLarge ## The message, with its RLN proof, exceeds the maximum message size.

  SendError* = object
    kind*: SendErrorKind
    desc*: string
    retryAfter*: Duration
      ## For `RateLimited`: the time until the next epoch, or 1 s when the RLN
      ## backend does not state the length of its epoch.

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
    T: type SendError, kind: SendErrorKind, desc: string, retryAfter = ZeroDuration
): T =
  return T(kind: kind, desc: desc, retryAfter: retryAfter)

func `$`*(error: SendError): string =
  ## The text of the refusal, with its kind in parentheses at the end.
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
