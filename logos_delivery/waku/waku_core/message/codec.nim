## Waku Message module: encoding and decoding
# See:
# - RFC 14: https://rfc.vac.dev/spec/14/
# - Proto definition: https://github.com/vacp2p/waku/blob/main/waku/message/v1/message.proto
{.push raises: [].}

import ../../common/protobuf_ext
import ../../common/protobuf

import ../time, ./message

type WakuMessagePB {.proto2.} = object
  payload {.fieldNumber: 1, required.}: seq[byte]
  contentTopic {.fieldNumber: 2, required.}: string
  version {.fieldNumber: 3, pint.}: Opt[uint32]
  timestamp {.fieldNumber: 10, sint.}: Opt[int64]
  meta {.fieldNumber: 11.}: Opt[seq[byte]]
  proof {.fieldNumber: 21.}: Opt[seq[byte]]
  ephemeral {.fieldNumber: 31.}: Opt[bool]

proc encode*(message: WakuMessage): seq[byte] =
  Protobuf.encode(
    WakuMessagePB(
      payload: message.payload,
      contentTopic: message.contentTopic,
      version: Opt.some(message.version),
      timestamp: Opt.some(int64(message.timestamp)),
      meta: Opt.some(message.meta),
      proof: Opt.some(message.proof),
      ephemeral: Opt.some(message.ephemeral),
    )
  )

proc decodeWakuMessage(buffer: seq[byte]): ProtobufResult[WakuMessage] =
  var pb: WakuMessagePB
  try:
    pb = Protobuf.decode(buffer, WakuMessagePB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  let meta = pb.meta.get(@[])
  if meta.len > MaxMetaAttrLength:
    return err(protobuf.ProtobufError.invalidLengthField("meta"))

  ok(
    WakuMessage(
      payload: pb.payload,
      contentTopic: pb.contentTopic,
      meta: meta,
      version: pb.version.get(0'u32),
      timestamp: Timestamp(pb.timestamp.get(0'i64)),
      ephemeral: pb.ephemeral.get(false),
      proof: pb.proof.get(@[]),
    )
  )

proc decode*(T: type WakuMessage, buffer: seq[byte]): ProtobufResult[T] =
  decodeWakuMessage(buffer)

# WakuMessage as a nested length-delimited field.
func supportsPacked*(T: type WakuMessage, ProtoType: type ProtobufExt): bool =
  false

func computeFieldSize*(
    field: int,
    value: WakuMessage,
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  computeFieldSize(field, encode(value), pbytes, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: WakuMessage,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, encode(value), pbytes, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var WakuMessage,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var s: seq[byte]
  if readFieldInto(stream, s, header, pbytes):
    let decoded = WakuMessage.decode(s)
    if decoded.isOk():
      value = decoded.get()
      true
    else:
      raise (ref ProtobufValueError)(msg: "Invalid nested WakuMessage")
  else:
    false
