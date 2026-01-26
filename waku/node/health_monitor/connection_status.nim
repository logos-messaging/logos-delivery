import chronos, results, std/strutils

type ConnectionStatus* {.pure.} = enum
  Disconnected = "Disconnected"
  PartiallyConnected = "PartiallyConnected"
  Connected = "Connected"

proc init*(t: typedesc[ConnectionStatus], strRep: string): Result[ConnectionStatus, string] =
  try:
    let status = parseEnum[ConnectionStatus](strRep)
    return ok(status)
  except ValueError:
    return err("Invalid ConnectionStatus string representation: " & strRep)

type ConnectionStatusChangeHandler* =
  proc(status: ConnectionStatus): Future[void] {.gcsafe, raises: [Defect].}
