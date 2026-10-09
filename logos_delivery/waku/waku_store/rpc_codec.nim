{.push raises: [].}

import results, chronicles, metrics
import ../common/protobuf, ../waku_core, ./common, ./protocol_metrics

logScope:
  topics = "waku store"

const DefaultMaxQuerySize* = 10 * 1024 * 1024
  ## The largest store query that a store node reads. A message hash takes 34
  ## bytes, so a hash query can have about 300 000 hashes.

func maxQueryResponseSize*(maxMessageSize: int): int =
  ## The largest store response that a client reads: a full page of messages
  ## of `maxMessageSize`.
  int(MaxPageSize) * (maxMessageSize + DefaultSafetyBufferProtocolOverhead)

const DefaultMaxQueryResponseSize* =
  maxQueryResponseSize(int(DefaultMaxWakuMessageSize))
  ## The response limit for the default maximum message size.

proc validateDecoded(keyValue: var WakuMessageKeyValue): ProtobufResult[void] =
  if keyValue.messageHash == default(WakuMessageHash):
    return err(ProtobufError.missingRequiredField("message_hash"))
  # The message and the topic are a pair. If one of them is missing, the
  # decode keeps neither.
  if keyValue.message.isSome() != keyValue.pubsubTopic.isSome():
    keyValue.message = Opt.none(WakuMessage)
    keyValue.pubsubTopic = Opt.none(PubsubTopic)
  if keyValue.message.isSome():
    return validateWakuMessageFields(keyValue.message.get())
  ok()

protobufCodec(WakuMessageKeyValue, validateDecoded)

# A store node can have a message that this client refuses. So the decode
# reads each key-value of field 20 independently, and it removes a key-value
# that does not decode or that the validator refuses. It keeps the other
# key-values and the cursor of the page.

func supportsPacked(
    _: type seq[WakuMessageKeyValue], ProtoType: type ProtobufExt
): bool =
  false

func computeFieldSize(
    field: int,
    value: seq[WakuMessageKeyValue],
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  var size = 0
  for keyValue in value:
    size += computeFieldSize(field, keyValue, pbytes, false)
  size

proc writeField(
    stream: OutputStream,
    field: int,
    value: seq[WakuMessageKeyValue],
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  for keyValue in value:
    writeField(stream, field, keyValue, pbytes, false)

proc readFieldInto(
    stream: InputStream,
    value: var seq[WakuMessageKeyValue],
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var data: seq[byte]
  if not readFieldInto(stream, data, header, pbytes):
    return false
  let keyValue = WakuMessageKeyValue.decode(data).valueOr:
    debug "Dropping a store key-value that does not decode or that the validator refuses",
      error = $error
    logos_delivery_store_errors.inc(labelValues = [DroppedKeyValue])
    return true
  value.add(keyValue)
  true

protobufCodec(StoreQueryRequest)
protobufCodec(StoreQueryResponse)
