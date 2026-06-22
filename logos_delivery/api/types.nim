## logos_delivery/api/types — shared API type definitions.
##
## These derived (non-builtin) types are referenced by the BrokerInterface
## contracts (LogosDeliveryInterface / MessagingClientInterface /
## ReliableChannelManagerInterface) and were elevated here from their original
## modules so the API surface has a single types home. Each original module now
## imports this module and re-exports the moved entity, so existing call sites
## are unaffected.
##
## NOTE (accepted layering inversion): `WakuMessage` and `ContentTopic` were
## physically moved out of `waku_core/`, so `waku_core/message` now depends on
## this module (which pulls in nim-sds via the channel id types).

{.push raises: [].}

import libp2p/crypto/crypto, std/times, chronos
import std/hashes

import
  logos_delivery/waku/utils/requests as request_utils
    # generateRequestId (used by RequestId.new); lost when the procs were
    # consolidated here during the type-elevation refactor.

import
  logos_delivery/waku/waku_core/time
    # Timestamp: TODO: this needs to be elevated into interface level.

import types/sds_message_id # nim-sds: SdsChannelID, SdsParticipantID (leaf)

# SdsParticipantID (and SdsChannelID, needed by ChannelId) are NOT moved — they
# belong to nim-sds; they are imported and explicitly re-exported here.
export sds_message_id

type
  ContentTopic* = string

  RequestId* = distinct string

  ConnectionStatus* {.pure.} = enum
    Disconnected
    PartiallyConnected
    Connected

  WakuMode* {.pure.} = enum
    Core # full service node
    Edge # client-only node

  NodeInfoId* {.pure.} = enum
    Version
    Metrics
    MyMultiaddresses
    MyENR
    MyPeerId
    MyBoundPorts
    MyMixPubKey

  ChannelId* = SdsChannelID

  MessageEnvelope* = object
    contentTopic*: ContentTopic
    payload*: seq[byte]
    ephemeral*: bool
    meta*: seq[byte]
      ## Opaque wire-format marker carried on the underlying WakuMessage.
      ## Higher layers (e.g. Reliable Channel) stamp this so peers can route
      ## ingress traffic to their corresponding layer. Empty by default.

  WakuMessage* = object # Data payload transmitted.
    payload*: seq[byte]
    contentTopic*: ContentTopic ## content-based filtering identifier
    meta*: seq[byte] ## application specific metadata
    version*: uint32 ## payload-encryption discriminator (Whisper/WakuV1 compat)
    timestamp*: Timestamp ## sender generated timestamp
    ephemeral*: bool ## transient (not-to-be-stored) marker
    proof*: seq[byte] ## RFC 17 spam-protection proof (rln-relay)

## ===== helpers =====
##
proc new*(T: typedesc[RequestId], rng: crypto.Rng): T =
  ## Generate a new RequestId using the provided RNG.
  RequestId(request_utils.generateRequestId(rng))

proc `$`*(r: RequestId): string {.inline.} =
  string(r)

proc `==`*(a, b: RequestId): bool {.inline.} =
  string(a) == string(b)

proc hash*(r: RequestId): Hash =
  ## Allows `RequestId` to be used as a `Table` key.
  hash(string(r))

proc generateRequestId*(rng: crypto.Rng): RequestId =
  RequestId(request_utils.generateRequestId(rng))

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
  return wm

{.pop.}
