{.push raises: [].}

import chronicles, json_serialization, json_serialization/std/options
import ../../../waku_node, ../serdes
import std/typetraits

#### Types

type DebugWakuInfo* = object
  listenAddresses*: seq[string]
  enrUri*: Option[string]
  mixPubKey*: Option[string]

#### Type conversion

proc toDebugWakuInfo*(nodeInfo: WakuInfo): DebugWakuInfo =
  DebugWakuInfo(
    listenAddresses: nodeInfo.listenAddresses,
    enrUri: some(nodeInfo.enrUri),
    mixPubKey: nodeInfo.mixPubKey,
  )

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: DebugWakuInfo
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("listenAddresses", value.listenAddresses)
  if value.enrUri.isSome():
    writer.writeField("enrUri", value.enrUri.get())
  if value.mixPubKey.isSome():
    writer.writeField("mixPubKey", value.mixPubKey.get())
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var DebugWakuInfo
) {.raises: [SerializationError, IOError].} =
  var
    listenAddresses: Option[seq[string]]
    enrUri: Option[string]

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
    else:
      unrecognizedFieldWarning(value)

  if listenAddresses.isNone():
    reader.raiseUnexpectedValue("Field `listenAddresses` is missing")

  value = DebugWakuInfo(
    listenAddresses: listenAddresses.get, enrUri: enrUri, mixPubKey: value.mixPubKey
  )
