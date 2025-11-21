{.push raises: [].}

import bearssl/rand, std/times, chronos, chronicles
import stew/byteutils
import waku/utils/requests as request_utils
import waku/waku_core/[topics/content_topic, message/message, time]
import waku/requests/requests

logScope:
  topics = "message envelope"

type
  MessageEnvelope* = object
    contentTopic*: ContentTopic
    payload*: seq[byte]
    ephemeral*: bool

  RequestId* = distinct string

  NodeHealth* {.pure.} = enum
    Healthy
    MinimallyHealthy
    Unhealthy

proc newRequestId*(rng: ref HmacDrbgContext): RequestId =
  ## Generate a new RequestId using the provided RNG.
  RequestId(request_utils.generateRequestId(rng))

proc `$`*(r: RequestId): string {.inline.} =
  string(r)

proc init*(
    T: type MessageEnvelope,
    contentTopic: ContentTopic,
    payload: seq[byte] | string,
    ephemeral: bool = false,
): MessageEnvelope =
  when payload is seq[byte]:
    MessageEnvelope(contentTopic: contentTopic, payload: payload, ephemeral: ephemeral)
  else:
    MessageEnvelope(
      contentTopic: contentTopic, payload: payload.toBytes(), ephemeral: ephemeral
    )

proc toWakuMessage*(envelope: MessageEnvelope): WakuMessage =
  ## Convert a MessageEnvelope to a WakuMessage.
  var wm = WakuMessage(
    contentTopic: envelope.contentTopic,
    payload: envelope.payload,
    ephemeral: envelope.ephemeral,
    timestamp: getNanosecondTime(getTime().toUnixFloat()),
  )

  # TODO: First find out if proof is needed at all
  let requestedProof = (
    waitFor RequestGenerateRlnProof.request(wm, getTime().toUnixFloat())
  ).valueOr:
    warn "Failed to add RLN proof to WakuMessage: ", error = error
    return wm

  wm.proof = requestedProof.proof
  return wm

{.pop.}
