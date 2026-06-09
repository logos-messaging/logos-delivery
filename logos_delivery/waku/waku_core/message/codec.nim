## Waku Message module: encoding and decoding
# See:
# - RFC 14: https://rfc.vac.dev/spec/14/
# - Proto definition: https://github.com/vacp2p/waku/blob/main/waku/message/v1/message.proto
{.push raises: [].}

import ../../common/protobuf, ../topics, ../time, ./message

proc encode*(message: WakuMessage): ProtoBuffer =
  var buf = initProtoBuffer()

  buf.write3(1, message.payload)
  buf.write3(2, message.contentTopic)
  buf.write3(3, message.version)
  buf.write3(10, zint64(message.timestamp))
  buf.write3(11, message.meta)
  buf.write3(21, message.proof)
  buf.write3(31, uint32(message.ephemeral))
  buf.finish3()

  buf

proc decode*(T: type WakuMessage, buffer: seq[byte]): ProtobufResult[T] =
  var msg = WakuMessage()
  let pb = initProtoBuffer(buffer)

  var payload: seq[byte]
  if not ?pb.getField(1, payload):
    return err(ProtobufError.missingRequiredField("payload"))
  else:
    msg.payload = payload

  var topic: ContentTopic
  if not ?pb.getField(2, topic):
    return err(ProtobufError.missingRequiredField("content_topic"))
  else:
    msg.contentTopic = topic

  var version: uint32
  if not ?pb.getField(3, version):
    msg.version = 0
  else:
    msg.version = version

  var timestamp: zint64
  if not ?pb.getField(10, timestamp):
    msg.timestamp = Timestamp(0)
  else:
    msg.timestamp = Timestamp(timestamp)

  var meta: seq[byte]
  if not ?pb.getField(11, meta):
    msg.meta = @[]
  else:
    if meta.len > MaxMetaAttrLength:
      return err(ProtobufError.invalidLengthField("meta"))

    msg.meta = meta

  # this is part of https://rfc.vac.dev/spec/17/ spec
  var proof: seq[byte]
  if not ?pb.getField(21, proof):
    msg.proof = @[]
  else:
    msg.proof = proof

  var ephemeral: uint32
  if not ?pb.getField(31, ephemeral):
    msg.ephemeral = false
  else:
    msg.ephemeral = bool(ephemeral)

  ok(msg)
