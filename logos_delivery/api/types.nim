{.push raises: [].}

import libp2p/crypto/crypto, chronos, results
import stew/byteutils
import logos_delivery/waku/utils/requests as request_utils
import logos_delivery/waku/waku_core/[topics/content_topic, message/message, time]

export content_topic, message, time

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

  HistoryQuery* = object
    ## A query for the messages of one content topic in a time range.
    ## The times are nanoseconds from the Unix epoch.
    contentTopic*: ContentTopic
    startTime*: Timestamp
      ## The range starts at this timestamp.
      ## It is at most `MaxHistoryQueryRange` before the end.
    endTime*: Opt[Timestamp]
      ## The range ends before this timestamp.
      ## It is at most `MaxMessageTimestampVariance` after the call.
      ## None is that latest end, because a sender's clock can be up to that far ahead.

proc new*(T: typedesc[RequestId], rng: crypto.Rng): T =
  ## Generate a new RequestId using the provided RNG.
  RequestId(request_utils.generateRequestId(rng))

proc `$`*(r: RequestId): string {.inline.} =
  string(r)

proc `==`*(a, b: RequestId): bool {.inline.} =
  string(a) == string(b)

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

func init*(
    T: type HistoryQuery,
    contentTopic: ContentTopic,
    startTime: Timestamp,
    endTime = Opt.none(Timestamp),
): HistoryQuery =
  HistoryQuery(contentTopic: contentTopic, startTime: startTime, endTime: endTime)

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
