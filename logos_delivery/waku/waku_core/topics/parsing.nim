{.push raises: [].}

import results

type
  ParsingErrorKind* {.pure.} = enum
    InvalidFormat
    MissingPart

  ParsingError* = object
    case kind*: ParsingErrorKind
    of InvalidFormat:
      cause*: string
    of MissingPart:
      part*: string

type ParsingResult*[T] = Result[T, ParsingError]

proc invalidFormat*(T: type ParsingError, cause = "invalid format"): T =
  ParsingError(kind: ParsingErrorKind.InvalidFormat, cause: cause)

proc missingPart*(T: type ParsingError, part = "unknown"): T =
  ParsingError(kind: ParsingErrorKind.MissingPart, part: part)

proc `$`*(err: ParsingError): string =
  case err.kind
  of ParsingErrorKind.InvalidFormat:
    return "invalid format: " & err.cause
  of ParsingErrorKind.MissingPart:
    return "missing part: " & err.part
