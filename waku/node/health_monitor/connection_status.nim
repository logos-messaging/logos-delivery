import chronos, results, std/strutils, ../../api/types

export ConnectionStatus

proc init*(
    t: typedesc[ConnectionStatus], strRep: string
): Result[ConnectionStatus, string] =
  try:
    let status = parseEnum[ConnectionStatus](strRep)
    return ok(status)
  except ValueError:
    return err("Invalid ConnectionStatus string representation: " & strRep)

type ConnectionStatusChangeHandler* =
  proc(status: ConnectionStatus): Future[void] {.gcsafe, raises: [Defect].}
