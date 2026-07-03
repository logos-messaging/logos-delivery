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

#### Event observability DTOs
##
## Send-related events (sent / propagated / error) are grouped per request id;
## received messages are cached for polling. Both are populated by the broker
## listeners installed in the messaging REST handlers.

type
  SendEventKind* {.pure.} = enum
    Sent = "sent"
    Propagated = "propagated"
    Error = "error"

  SendEventRecord* = object
    kind*: SendEventKind
    messageHash*: string
    error*: string ## populated only for `Error`
    timestamp*: int64 ## nanoseconds, stamped when cached

  SendStatus* = object ## All send events observed so far for a single request id.
    requestId*: string
    events*: seq[SendEventRecord]

  ReceivedMessageRecord* = object
    messageHash*: string
    message*: MessagingMessage
    timestamp*: int64 ## nanoseconds, stamped when cached

proc toMessagingMessage*(msg: WakuMessage): MessagingMessage =
  MessagingMessage(
    payload: base64.encode(msg.payload),
    contentTopic: msg.contentTopic,
    ephemeral: some(msg.ephemeral),
    meta:
      if msg.meta.len > 0:
        some(base64.encode(msg.meta))
      else:
        none(Base64String),
  )

#### Event DTO serialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: SendEventRecord
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("kind", $value.kind)
  writer.writeField("messageHash", value.messageHash)
  if value.error.len > 0:
    writer.writeField("error", value.error)
  writer.writeField("timestamp", value.timestamp)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: SendStatus
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  writer.writeField("events", value.events)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: ReceivedMessageRecord
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("messageHash", value.messageHash)
  writer.writeField("message", value.message)
  writer.writeField("timestamp", value.timestamp)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var SendEventKind
) {.raises: [SerializationError, IOError].} =
  let s = reader.readValue(string)
  case s
  of "sent":
    value = SendEventKind.Sent
  of "propagated":
    value = SendEventKind.Propagated
  of "error":
    value = SendEventKind.Error
  else:
    reader.raiseUnexpectedValue("Invalid send event kind: " & s)

proc readValue*(
    reader: var JsonReader[RestJson], value: var SendEventRecord
) {.raises: [SerializationError, IOError].} =
  var
    kind = none(SendEventKind)
    messageHash = ""
    error = ""
    timestamp = int64(0)

  for fieldName in readObjectFields(reader):
    case fieldName
    of "kind":
      kind = some(reader.readValue(SendEventKind))
    of "messageHash":
      messageHash = reader.readValue(string)
    of "error":
      error = reader.readValue(string)
    of "timestamp":
      timestamp = reader.readValue(int64)
    else:
      unrecognizedFieldWarning(value)

  if kind.isNone():
    reader.raiseUnexpectedValue("Field `kind` is missing")

  value = SendEventRecord(
    kind: kind.get(), messageHash: messageHash, error: error, timestamp: timestamp
  )

proc readValue*(
    reader: var JsonReader[RestJson], value: var SendStatus
) {.raises: [SerializationError, IOError].} =
  var
    requestId = ""
    events: seq[SendEventRecord] = @[]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "requestId":
      requestId = reader.readValue(string)
    of "events":
      events = reader.readValue(seq[SendEventRecord])
    else:
      unrecognizedFieldWarning(value)

  value = SendStatus(requestId: requestId, events: events)

proc readValue*(
    reader: var JsonReader[RestJson], value: var ReceivedMessageRecord
) {.raises: [SerializationError, IOError].} =
  var
    messageHash = ""
    message = MessagingMessage()
    timestamp = int64(0)

  for fieldName in readObjectFields(reader):
    case fieldName
    of "messageHash":
      messageHash = reader.readValue(string)
    of "message":
      message = reader.readValue(MessagingMessage)
    of "timestamp":
      timestamp = reader.readValue(int64)
    else:
      unrecognizedFieldWarning(value)

  value = ReceivedMessageRecord(
    messageHash: messageHash, message: message, timestamp: timestamp
  )
