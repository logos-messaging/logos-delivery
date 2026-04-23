{.push raises: [].}

import chronicles, json_serialization, json_serialization/std/options
import ../../../waku_node, ../serdes
import std/typetraits

#### Types

type DebugWakuInfo* = object
  listenAddresses*: seq[string]
  enrUri*: Option[string]
  mixPubKey*: Option[string]
  ports*: BoundPorts

#### Type conversion

proc toDebugWakuInfo*(nodeInfo: WakuInfo): DebugWakuInfo =
  DebugWakuInfo(
    listenAddresses: nodeInfo.listenAddresses,
    enrUri: some(nodeInfo.enrUri),
    mixPubKey: nodeInfo.mixPubKey,
    ports: nodeInfo.ports,
  )

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: BoundPorts
) {.raises: [IOError].} =
  writer.beginRecord()
  if value.tcp.isSome():
    writer.writeField("tcp", value.tcp.get())
  if value.webSocket.isSome():
    writer.writeField("webSocket", value.webSocket.get())
  if value.rest.isSome():
    writer.writeField("rest", value.rest.get())
  if value.discv5Udp.isSome():
    writer.writeField("discv5Udp", value.discv5Udp.get())
  if value.metrics.isSome():
    writer.writeField("metrics", value.metrics.get())
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var BoundPorts
) {.raises: [SerializationError, IOError].} =
  for fieldName in readObjectFields(reader):
    case fieldName
    of "tcp":
      value.tcp = some(reader.readValue(uint16))
    of "webSocket":
      value.webSocket = some(reader.readValue(uint16))
    of "rest":
      value.rest = some(reader.readValue(uint16))
    of "discv5Udp":
      value.discv5Udp = some(reader.readValue(uint16))
    of "metrics":
      value.metrics = some(reader.readValue(uint16))
    else:
      unrecognizedFieldWarning(value)

proc writeValue*(
    writer: var JsonWriter[RestJson], value: DebugWakuInfo
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("listenAddresses", value.listenAddresses)
  if value.enrUri.isSome():
    writer.writeField("enrUri", value.enrUri.get())
  if value.mixPubKey.isSome():
    writer.writeField("mixPubKey", value.mixPubKey.get())
  writer.writeField("ports", value.ports)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var DebugWakuInfo
) {.raises: [SerializationError, IOError].} =
  var
    listenAddresses: Option[seq[string]]
    enrUri: Option[string]
    ports: BoundPorts

  for fieldName in readObjectFields(reader):
    case fieldName
    of "listenAddresses":
      if listenAddresses.isSome():
        reader.raiseUnexpectedField(
          "Multiple `listenAddresses` fields found", "DebugWakuInfo"
        )
      listenAddresses = some(reader.readValue(seq[string]))
    of "enrUri":
      if enrUri.isSome():
        reader.raiseUnexpectedField("Multiple `enrUri` fields found", "DebugWakuInfo")
      enrUri = some(reader.readValue(string))
    of "mixPubKey":
      if value.mixPubKey.isSome():
        reader.raiseUnexpectedField(
          "Multiple `mixPubKey` fields found", "DebugWakuInfo"
        )
      value.mixPubKey = some(reader.readValue(string))
    of "ports":
      ports = reader.readValue(BoundPorts)
    else:
      unrecognizedFieldWarning(value)

  if listenAddresses.isNone():
    reader.raiseUnexpectedValue("Field `listenAddresses` is missing")

  value = DebugWakuInfo(
    listenAddresses: listenAddresses.get,
    enrUri: enrUri,
    mixPubKey: value.mixPubKey,
    ports: ports,
  )
