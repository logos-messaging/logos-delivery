{.push raises: [].}

import results, chronicles, metrics
import ../common/protobuf, ../waku_core, ./common, ./protocol_metrics

logScope:
  topics = "waku store"

const DefaultMaxRpcSize* = -1

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

proc validateDecoded(req: StoreQueryRequest): ProtobufResult[void] =
  if req.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  ok()

proc validateDecoded(res: StoreQueryResponse): ProtobufResult[void] =
  if res.requestId.len == 0:
    return err(ProtobufError.missingRequiredField("request_id"))
  if res.statusCode == 0:
    return err(ProtobufError.missingRequiredField("status_code"))
  ok()

protobufCodec(StoreQueryRequest, validateDecoded)
protobufCodec(StoreQueryResponse, validateDecoded)
