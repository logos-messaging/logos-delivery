{.push raises: [].}

import
  std/[sets, strformat],
  chronicles,
  results,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import
  logos_delivery/waku/common/base64,
  logos_delivery/waku/rest_api/endpoint/serdes,
  logos_delivery/api/types

export types

#### Types

type MessagingMessage* = object
  ## REST wire representation of a `MessageEnvelope`. `payload` is base64.
  payload*: Base64String
  contentTopic*: ContentTopic
  ephemeral*: Option[bool]
  meta*: Option[Base64String]

type
  MessagingPostMessageRequest* = MessagingMessage

  MessagingSendResponse* = object
    ## Returned by the send endpoint; correlates with `MessageSentEvent` /
    ## `MessageErrorEvent`.
    requestId*: string

#### Type conversion

proc toMessageEnvelope*(msg: MessagingMessage): Result[MessageEnvelope, string] =
  let
    payload = ?msg.payload.decode()
    meta = ?msg.meta.get(Base64String("")).decode()

  return ok(
    MessageEnvelope(
      contentTopic: msg.contentTopic,
      payload: payload,
      ephemeral: msg.ephemeral.get(false),
      meta: meta,
    )
  )

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: MessagingMessage
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("payload", value.payload)
  writer.writeField("contentTopic", value.contentTopic)
  if value.ephemeral.isSome():
    writer.writeField("ephemeral", value.ephemeral.get())
  if value.meta.isSome():
    writer.writeField("meta", value.meta.get())
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var MessagingMessage
) {.raises: [SerializationError, IOError].} =
  var
    payload = none(Base64String)
    contentTopic = none(ContentTopic)
    ephemeral = none(bool)
    meta = none(Base64String)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for repeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "MessagingMessage")

    case fieldName
    of "payload":
      payload = some(reader.readValue(Base64String))
    of "contentTopic":
      contentTopic = some(reader.readValue(ContentTopic))
    of "ephemeral":
      ephemeral = some(reader.readValue(bool))
    of "meta":
      meta = some(reader.readValue(Base64String))
    else:
      unrecognizedFieldWarning(value)

  if payload.isNone() or isEmptyOrWhitespace(string(payload.get())):
    reader.raiseUnexpectedValue("Field `payload` is missing or empty")

  if contentTopic.isNone() or contentTopic.get().isEmptyOrWhitespace():
    reader.raiseUnexpectedValue("Field `contentTopic` is missing or empty")

  value = MessagingMessage(
    payload: payload.get(),
    contentTopic: contentTopic.get(),
    ephemeral: ephemeral,
    meta: meta,
  )

proc writeValue*(
    writer: var JsonWriter[RestJson], value: MessagingSendResponse
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var MessagingSendResponse
) {.raises: [SerializationError, IOError].} =
  var requestId = none(string)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "MessagingSendResponse")

    case fieldName
    of "requestId":
      requestId = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning(value)

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  value = MessagingSendResponse(requestId: requestId.get())
