import chronos, results, std/strutils

type HealthStatus* {.pure.} = enum
  INITIALIZING
  SYNCHRONIZING
  READY
  NOT_READY
  NOT_MOUNTED
  SHUTTING_DOWN

proc init*(t: typedesc[HealthStatus], strRep: string): Result[HealthStatus, string] =
  try:
    let status = parseEnum[HealthStatus](strRep)
    return ok(status)
  except ValueError:
    return err("Invalid HealthStatus string representation: " & strRep)

