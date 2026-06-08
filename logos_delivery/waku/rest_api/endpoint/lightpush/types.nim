{.push raises: [].}

import
  std/[sets, strformat],
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client]

import ../../../waku_core, ../relay/types as relay_types, ../serdes

export relay_types

#### Types

type
  PushRequest* = object
    pubsubTopic*: Option[PubSubTopic]
    message*: RelayWakuMessage

  PushResponse* = object
    statusDesc*: Option[string]
    relayPeerCount*: Option[uint32]

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
    pubsubTopic = none(PubsubTopic)
    message = none(RelayWakuMessage)

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
      pubsubTopic = some(reader.readValue(PubsubTopic))
    of "message":
      message = some(reader.readValue(RelayWakuMessage))
    else:
      unrecognizedFieldWarning(value)

  if message.isNone():
    reader.raiseUnexpectedValue("Field `message` is missing")

  value = PushRequest(
    pubsubTopic:
      if pubsubTopic.isNone() or pubsubTopic.get() == "":
        none(string)
      else:
        some(pubsubTopic.get()),
    message: message.get(),
  )

proc writeValue*(
    writer: var JsonWriter[RestJson], value: PushResponse
) {.raises: [IOError].} =
  writer.beginRecord()
  if value.statusDesc.isSome():
    writer.writeField("statusDesc", value.statusDesc.get())
  if value.relayPeerCount.isSome():
    writer.writeField("relayPeerCount", value.relayPeerCount.get())
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var PushResponse
) {.raises: [SerializationError, IOError].} =
  var
    statusDesc = none(string)
    relayPeerCount = none(uint32)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "PushResponse")

    case fieldName
    of "statusDesc":
      statusDesc = some(reader.readValue(string))
    of "relayPeerCount":
      relayPeerCount = some(reader.readValue(uint32))
    else:
      unrecognizedFieldWarning(value)

  if relayPeerCount.isNone() and statusDesc.isNone():
    reader.raiseUnexpectedValue(
      "Fields are missing, either `relayPeerCount` or `statusDesc` must be present"
    )

  value = PushResponse(statusDesc: statusDesc, relayPeerCount: relayPeerCount)
