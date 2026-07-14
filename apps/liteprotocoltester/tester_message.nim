{.push raises: [].}

import
  results,
  chronicles,
  json_serialization,
  json_serialization/pkg/results,
  json_serialization/lexer

import logos_delivery/waku/rest_api/endpoint/serdes

type ProtocolTesterMessage* = object
  sender*: string
  index*: uint32
  count*: uint32
  startedAt*: int64
  sinceStart*: int64
  sincePrev*: int64
  size*: uint64

proc writeValue*(
    writer: var JsonWriter[RestJson], value: ProtocolTesterMessage
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("sender", value.sender)
  writer.writeField("index", value.index)
  writer.writeField("count", value.count)
  writer.writeField("startedAt", value.startedAt)
  writer.writeField("sinceStart", value.sinceStart)
  writer.writeField("sincePrev", value.sincePrev)
  writer.writeField("size", value.size)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var ProtocolTesterMessage
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    sender: Opt[string]
    index: Opt[uint32]
    count: Opt[uint32]
    startedAt: Opt[int64]
    sinceStart: Opt[int64]
    sincePrev: Opt[int64]
    size: Opt[uint64]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "sender":
      if sender.isSome():
        reader.raiseUnexpectedField(
          "Multiple `sender` fields found", "ProtocolTesterMessage"
        )
      sender = Opt.some(reader.readValue(string))
    of "index":
      if index.isSome():
        reader.raiseUnexpectedField(
          "Multiple `index` fields found", "ProtocolTesterMessage"
        )
      index = Opt.some(reader.readValue(uint32))
    of "count":
      if count.isSome():
        reader.raiseUnexpectedField(
          "Multiple `count` fields found", "ProtocolTesterMessage"
        )
      count = Opt.some(reader.readValue(uint32))
    of "startedAt":
      if startedAt.isSome():
        reader.raiseUnexpectedField(
          "Multiple `startedAt` fields found", "ProtocolTesterMessage"
        )
      startedAt = Opt.some(reader.readValue(int64))
    of "sinceStart":
      if sinceStart.isSome():
        reader.raiseUnexpectedField(
          "Multiple `sinceStart` fields found", "ProtocolTesterMessage"
        )
      sinceStart = Opt.some(reader.readValue(int64))
    of "sincePrev":
      if sincePrev.isSome():
        reader.raiseUnexpectedField(
          "Multiple `sincePrev` fields found", "ProtocolTesterMessage"
        )
      sincePrev = Opt.some(reader.readValue(int64))
    of "size":
      if size.isSome():
        reader.raiseUnexpectedField(
          "Multiple `size` fields found", "ProtocolTesterMessage"
        )
      size = Opt.some(reader.readValue(uint64))
    else:
      unrecognizedFieldWarning(value)

  if sender.isNone():
    reader.raiseUnexpectedValue("Field `sender` is missing")

  if index.isNone():
    reader.raiseUnexpectedValue("Field `index` is missing")

  if count.isNone():
    reader.raiseUnexpectedValue("Field `count` is missing")

  if startedAt.isNone():
    reader.raiseUnexpectedValue("Field `startedAt` is missing")

  if sinceStart.isNone():
    reader.raiseUnexpectedValue("Field `sinceStart` is missing")

  if sincePrev.isNone():
    reader.raiseUnexpectedValue("Field `sincePrev` is missing")

  if size.isNone():
    reader.raiseUnexpectedValue("Field `size` is missing")

  value = ProtocolTesterMessage(
    sender: sender.get(),
    index: index.get(),
    count: count.get(),
    startedAt: startedAt.get(),
    sinceStart: sinceStart.get(),
    sincePrev: sincePrev.get(),
    size: size.get(),
  )
