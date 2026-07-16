{.push raises: [].}

import
  results,
  std/[sets, strformat],
  chronicles,
  json_serialization,
  json_serialization/pkg/results,
  presto/[route, client]

import ../../../waku_core, ../relay/types as relay_types, ../serdes

export relay_types

#### Types

type PushRequest* = object
  pubsubTopic*: Opt[PubSubTopic]
  message*: RelayWakuMessage

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: PushRequest
) {.raises: [IOError].} =
  writer.beginRecord()
  if value.pubsubTopic.isSome():
    writer.writeField("pubsubTopic", value.pubsubTopic.get())
  writer.writeField("message", value.message)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var PushRequest
) {.raises: [SerializationError, IOError].} =
  var
    pubsubTopic = Opt.none(PubsubTopic)
    message = Opt.none(RelayWakuMessage)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "PushRequest")

    case fieldName
    of "pubsubTopic":
      pubsubTopic = Opt.some(reader.readValue(PubsubTopic))
    of "message":
      message = Opt.some(reader.readValue(RelayWakuMessage))
    else:
      unrecognizedFieldWarning(value)

  if message.isNone():
    reader.raiseUnexpectedValue("Field `message` is missing")

  value = PushRequest(
    pubsubTopic:
      if pubsubTopic.isNone() or pubsubTopic.get() == "":
        Opt.none(string)
      else:
        Opt.some(pubsubTopic.get()),
    message: message.get(),
  )
