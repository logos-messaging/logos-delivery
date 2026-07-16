{.push raises: [].}

import results, chronicles, json_serialization, json_serialization/pkg/results
import ../../../waku_node, ../serdes
import std/typetraits

#### Types

type DebugWakuInfo* = object
  listenAddresses*: seq[string]
  enrUri*: Opt[string]
  mixPubKey*: Opt[string]

#### Type conversion

proc toDebugWakuInfo*(nodeInfo: WakuInfo): DebugWakuInfo =
  DebugWakuInfo(
    listenAddresses: nodeInfo.listenAddresses,
    enrUri: Opt.some(nodeInfo.enrUri),
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
    listenAddresses: Opt[seq[string]]
    enrUri: Opt[string]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "listenAddresses":
      if listenAddresses.isSome():
        reader.raiseUnexpectedField(
          "Multiple `listenAddresses` fields found", "DebugWakuInfo"
        )
      listenAddresses = Opt.some(reader.readValue(seq[string]))
    of "enrUri":
      if enrUri.isSome():
        reader.raiseUnexpectedField("Multiple `enrUri` fields found", "DebugWakuInfo")
      enrUri = Opt.some(reader.readValue(string))
    of "mixPubKey":
      if value.mixPubKey.isSome():
        reader.raiseUnexpectedField(
          "Multiple `mixPubKey` fields found", "DebugWakuInfo"
        )
      value.mixPubKey = Opt.some(reader.readValue(string))
    else:
      unrecognizedFieldWarning(value)

  if listenAddresses.isNone():
    reader.raiseUnexpectedValue("Field `listenAddresses` is missing")

  value = DebugWakuInfo(
    listenAddresses: listenAddresses.get, enrUri: enrUri, mixPubKey: value.mixPubKey
  )
