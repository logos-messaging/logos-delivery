{.push raises: [].}

import
  results,
  std/[sets, strformat],
  chronicles,
  json_serialization,
  json_serialization/pkg/results,
  presto/[route, client, common],
  libp2p/peerid
import ../../../common/base64, ../../../waku_core, ../serdes

#### Types

type FilterWakuMessage* = object
  payload*: Base64String
  contentTopic*: Opt[ContentTopic]
  version*: Opt[Natural]
  timestamp*: Opt[int64]
  meta*: Opt[Base64String]
  ephemeral*: Opt[bool]

type FilterGetMessagesResponse* = seq[FilterWakuMessage]

type FilterLegacySubscribeRequest* = object
  # Subscription request for legacy filter support
  pubsubTopic*: Opt[PubSubTopic]
  contentFilters*: seq[ContentTopic]

type FilterSubscriberPing* = object
  requestId*: string

type FilterSubscribeRequest* = object
  requestId*: string
  pubsubTopic*: Opt[PubSubTopic]
  contentFilters*: seq[ContentTopic]

type FilterUnsubscribeRequest* = object
  requestId*: string
  pubsubTopic*: Opt[PubSubTopic]
  contentFilters*: seq[ContentTopic]

type FilterUnsubscribeAllRequest* = object
  requestId*: string

type FilterSubscriptionResponse* = object
  requestId*: string
  statusDesc*: string

#### Type conversion

proc toFilterWakuMessage*(msg: WakuMessage): FilterWakuMessage =
  FilterWakuMessage(
    payload: base64.encode(msg.payload),
    contentTopic: Opt.some(msg.contentTopic),
    version: Opt.some(Natural(msg.version)),
    timestamp: Opt.some(msg.timestamp),
    meta:
      if msg.meta.len > 0:
        Opt.some(base64.encode(msg.meta))
      else:
        Opt.none(Base64String),
    ephemeral: Opt.some(msg.ephemeral),
  )

proc toWakuMessage*(msg: FilterWakuMessage, version = 0): Result[WakuMessage, string] =
  let
    payload = ?msg.payload.decode()
    contentTopic = msg.contentTopic.get(DefaultContentTopic)
    version = uint32(msg.version.get(version))
    timestamp = msg.timestamp.get(0)
    meta = ?msg.meta.get(Base64String("")).decode()
    ephemeral = msg.ephemeral.get(false)

  ok(
    WakuMessage(
      payload: payload,
      contentTopic: contentTopic,
      version: version,
      timestamp: timestamp,
      meta: meta,
      ephemeral: ephemeral,
    )
  )

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterWakuMessage
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("payload", value.payload)
  if value.contentTopic.isSome():
    writer.writeField("contentTopic", value.contentTopic.get())
  if value.version.isSome():
    writer.writeField("version", value.version.get())
  if value.timestamp.isSome():
    writer.writeField("timestamp", value.timestamp.get())
  if value.meta.isSome():
    writer.writeField("meta", value.meta.get())
  if value.ephemeral.isSome():
    writer.writeField("ephemeral", value.ephemeral.get())
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter, value: FilterLegacySubscribeRequest
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("pubsubTopic", value.pubsubTopic)
  writer.writeField("contentFilters", value.contentFilters)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterSubscriptionResponse
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  writer.writeField("statusDesc", value.statusDesc)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterSubscribeRequest
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  if value.pubsubTopic.isSome():
    writer.writeField("pubsubTopic", value.pubsubTopic.get())
  writer.writeField("contentFilters", value.contentFilters)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterSubscriberPing
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterUnsubscribeRequest
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  if value.pubsubTopic.isSome():
    writer.writeField("pubsubTopic", value.pubsubTopic.get())
  writer.writeField("contentFilters", value.contentFilters)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterUnsubscribeAllRequest
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterWakuMessage
) {.raises: [SerializationError, IOError].} =
  var
    payload = Opt.none(Base64String)
    contentTopic = Opt.none(ContentTopic)
    version = Opt.none(Natural)
    timestamp = Opt.none(int64)
    meta = Opt.none(Base64String)
    ephemeral = Opt.none(bool)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterWakuMessage")

    case fieldName
    of "payload":
      payload = Opt.some(reader.readValue(Base64String))
    of "contentTopic":
      contentTopic = Opt.some(reader.readValue(ContentTopic))
    of "version":
      version = Opt.some(reader.readValue(Natural))
    of "timestamp":
      timestamp = Opt.some(reader.readValue(int64))
    of "meta":
      meta = Opt.some(reader.readValue(Base64String))
    of "ephemeral":
      ephemeral = Opt.some(reader.readValue(bool))
    else:
      unrecognizedFieldWarning(value)

  if payload.isNone():
    reader.raiseUnexpectedValue("Field `payload` is missing")

  value = FilterWakuMessage(
    payload: payload.get(),
    contentTopic: contentTopic,
    version: version,
    timestamp: timestamp,
    meta: meta,
    ephemeral: ephemeral,
  )

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterLegacySubscribeRequest
) {.raises: [SerializationError, IOError].} =
  var
    pubsubTopic = Opt.none(PubsubTopic)
    contentFilters = Opt.none(seq[ContentTopic])

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterLegacySubscribeRequest")

    case fieldName
    of "pubsubTopic":
      pubsubTopic = Opt.some(reader.readValue(PubsubTopic))
    of "contentFilters":
      contentFilters = Opt.some(reader.readValue(seq[ContentTopic]))
    else:
      unrecognizedFieldWarning(value)

  if contentFilters.isNone():
    reader.raiseUnexpectedValue("Field `contentFilters` is missing")

  if contentFilters.get().len() == 0:
    reader.raiseUnexpectedValue("Field `contentFilters` is empty")

  value = FilterLegacySubscribeRequest(
    pubsubTopic:
      if pubsubTopic.isNone() or pubsubTopic.get() == "":
        Opt.none(string)
      else:
        Opt.some(pubsubTopic.get()),
    contentFilters: contentFilters.get(),
  )

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterSubscriberPing
) {.raises: [SerializationError, IOError].} =
  var requestId = Opt.none(string)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterSubscriberPing")

    case fieldName
    of "requestId":
      requestId = Opt.some(reader.readValue(string))
    else:
      unrecognizedFieldWarning(value)

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  value = FilterSubscriberPing(requestId: requestId.get())

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterSubscribeRequest
) {.raises: [SerializationError, IOError].} =
  var
    requestId = Opt.none(string)
    pubsubTopic = Opt.none(PubsubTopic)
    contentFilters = Opt.none(seq[ContentTopic])

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterSubscribeRequest")

    case fieldName
    of "requestId":
      requestId = Opt.some(reader.readValue(string))
    of "pubsubTopic":
      pubsubTopic = Opt.some(reader.readValue(PubsubTopic))
    of "contentFilters":
      contentFilters = Opt.some(reader.readValue(seq[ContentTopic]))
    else:
      unrecognizedFieldWarning(value)

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  if contentFilters.isNone():
    reader.raiseUnexpectedValue("Field `contentFilters` is missing")

  if contentFilters.get().len() == 0:
    reader.raiseUnexpectedValue("Field `contentFilters` is empty")

  value = FilterSubscribeRequest(
    requestId: requestId.get(),
    pubsubTopic:
      if pubsubTopic.isNone() or pubsubTopic.get() == "":
        Opt.none(string)
      else:
        Opt.some(pubsubTopic.get()),
    contentFilters: contentFilters.get(),
  )

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterUnsubscribeRequest
) {.raises: [SerializationError, IOError].} =
  var
    requestId = Opt.none(string)
    pubsubTopic = Opt.none(PubsubTopic)
    contentFilters = Opt.none(seq[ContentTopic])

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterUnsubscribeRequest")

    case fieldName
    of "requestId":
      requestId = Opt.some(reader.readValue(string))
    of "pubsubTopic":
      pubsubTopic = Opt.some(reader.readValue(PubsubTopic))
    of "contentFilters":
      contentFilters = Opt.some(reader.readValue(seq[ContentTopic]))
    else:
      unrecognizedFieldWarning(value)

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  if contentFilters.isNone():
    reader.raiseUnexpectedValue("Field `contentFilters` is missing")

  if contentFilters.get().len() == 0:
    reader.raiseUnexpectedValue("Field `contentFilters` is empty")

  value = FilterUnsubscribeRequest(
    requestId: requestId.get(),
    pubsubTopic:
      if pubsubTopic.isNone() or pubsubTopic.get() == "":
        Opt.none(string)
      else:
        Opt.some(pubsubTopic.get()),
    contentFilters: contentFilters.get(),
  )

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterUnsubscribeAllRequest
) {.raises: [SerializationError, IOError].} =
  var requestId = Opt.none(string)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterUnsubscribeAllRequest")

    case fieldName
    of "requestId":
      requestId = Opt.some(reader.readValue(string))
    else:
      unrecognizedFieldWarning(value)

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  value = FilterUnsubscribeAllRequest(requestId: requestId.get())

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterSubscriptionResponse
) {.raises: [SerializationError, IOError].} =
  var
    requestId = Opt.none(string)
    statusDesc = Opt.none(string)

  var keys = initHashSet[string]()
  for fieldName in readObjectFields(reader):
    # Check for reapeated keys
    if keys.containsOrIncl(fieldName):
      let err =
        try:
          fmt"Multiple `{fieldName}` fields found"
        except CatchableError:
          "Multiple fields with the same name found"
      reader.raiseUnexpectedField(err, "FilterSubscriptionResponse")

    case fieldName
    of "requestId":
      requestId = Opt.some(reader.readValue(string))
    of "statusDesc":
      statusDesc = Opt.some(reader.readValue(string))
    else:
      unrecognizedFieldWarning(value)

  if requestId.isNone():
    reader.raiseUnexpectedValue("Field `requestId` is missing")

  value = FilterSubscriptionResponse(
    requestId: requestId.get(), statusDesc: statusDesc.get("")
  )
