{.push raises: [].}

import results, chronicles, json_serialization, json_serialization/pkg/results
import ../serdes
import logos_delivery/api/types
import logos_delivery/waku/[waku_node, node/health_monitor]

#### Serialization and deserialization

proc writeValue*(
    writer: var JsonWriter[RestJson], value: ProtocolHealth
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField(value.protocol, $value.health)
  writer.writeField("desc", value.desc)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var ProtocolHealth
) {.gcsafe, raises: [SerializationError, IOError].} =
  var protocol = Opt.none(string)
  var health = Opt.none(HealthStatus)
  var desc = Opt.none(string)
  for fieldName in readObjectFields(reader):
    if fieldName == "desc":
      if desc.isSome():
        reader.raiseUnexpectedField("Multiple `desc` fields found", "ProtocolHealth")
      desc = Opt.some(reader.readValue(string))
    else:
      if protocol.isSome():
        reader.raiseUnexpectedField(
          "Multiple `protocol` fields and value found", "ProtocolHealth"
        )

      let fieldValue = reader.readValue(string)
      let h = HealthStatus.init(fieldValue).valueOr:
        reader.raiseUnexpectedValue("Invalid `health` value: " & $error)
      health = Opt.some(h)
      protocol = Opt.some(fieldName)

    value = ProtocolHealth(protocol: protocol.get(), health: health.get(), desc: desc)

proc writeValue*(
    writer: var JsonWriter[RestJson], value: HealthReport
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("nodeHealth", $value.nodeHealth)
  writer.writeField("connectionStatus", $value.connectionStatus)
  writer.writeField("protocolsHealth", value.protocolsHealth)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var HealthReport
) {.raises: [SerializationError, IOError].} =
  var
    nodeHealth: Opt[HealthStatus]
    connectionStatus: Opt[ConnectionStatus]
    protocolsHealth: Opt[seq[ProtocolHealth]]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "nodeHealth":
      if nodeHealth.isSome():
        reader.raiseUnexpectedField(
          "Multiple `nodeHealth` fields found", "HealthReport"
        )

      let health = HealthStatus.init(reader.readValue(string)).valueOr:
        reader.raiseUnexpectedValue("Invalid `health` value: " & $error)

      nodeHealth = Opt.some(health)
    of "connectionStatus":
      if connectionStatus.isSome():
        reader.raiseUnexpectedField(
          "Multiple `connectionStatus` fields found", "HealthReport"
        )

      let state = ConnectionStatus.init(reader.readValue(string)).valueOr:
        reader.raiseUnexpectedValue("Invalid `connectionStatus` value: " & $error)

      connectionStatus = Opt.some(state)
    of "protocolsHealth":
      if protocolsHealth.isSome():
        reader.raiseUnexpectedField(
          "Multiple `protocolsHealth` fields found", "HealthReport"
        )

      protocolsHealth = Opt.some(reader.readValue(seq[ProtocolHealth]))
    else:
      unrecognizedFieldWarning(value)

  if nodeHealth.isNone():
    reader.raiseUnexpectedValue("Field `nodeHealth` is missing")

  value = HealthReport(
    nodeHealth: nodeHealth.get,
    connectionStatus: connectionStatus.get,
    protocolsHealth: protocolsHealth.get(@[]),
  )
