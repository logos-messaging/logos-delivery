import std/[strutils, math], results, regex

proc parseMsgSize*(input: string): Result[uint64, string] =
  ## Parses size strings such as "1.2 KiB" or "3Kb" and returns the equivalent number of bytes
  ## if the parse task goes well. If not, it returns an error describing the problem.

  const RegexDef = """\s*(\d+([\,\.]\d*)?)\s*([Kk]{0,1}[i]?[Bb]{1})"""
  const RegexParseSize = re2(RegexDef)

  var m: RegexMatch2
  if input.match(RegexParseSize, m) == false:
    return err("error in parseSize. regex is not matching: " & RegexDef)

  var value: float

  try:
    value = parseFloat(input[m.captures[0]].replace(",", "."))
  except ValueError:
    return err(
      "invalid size in parseSize: " & getCurrentExceptionMsg() & " error parsing: " &
        input[m.captures[0]] & " KKK : " & $m
    )

  let units = input[m.captures[2]].toLowerAscii() # units is "kib", or "kb", or "b".

  var multiplier: float
  case units
  of "kb":
    multiplier = 1000
  of "kib":
    multiplier = 1024
  of "ib":
    return err("wrong units. ib or iB aren't allowed.")
  else: ## bytes
    multiplier = 1

  value = value * multiplier

  return ok(uint64(value))

proc parseCorrectMsgSize*(input: string): uint64 =
  ## This proc always returns an int and wraps the following proc:
  ##
  ##     proc parseMsgSize*(input: string): Result[int, string] = ...
  ##
  ## in case of error, it just returns 0, and this is expected to
  ## be called only from a controlled and well-known inputs

  let ret = parseMsgSize(input).valueOr:
    return 0
  return ret

proc parseRelayServiceRatio*(ratio: string): Result[(float, float), string] =
  ## Parses a relay/service ratio string to [ float, float ]. The total should sum 100%
  ## e.g., (0.4, 0.6) == parseRelayServiceRatio("40:60")
  let elements = ratio.split(":")
  if elements.len != 2:
    return err("expected format 'X:Y', ratio = " & ratio)

  var relayRatio, serviceRatio: float
  try:
    relayRatio = parseFloat(elements[0])
    serviceRatio = parseFloat(elements[1])
  except ValueError:
    return err("failed to parse ratio numbers: " & ratio)

  if relayRatio < 0 or serviceRatio < 0:
    return err("relay service ratio must be non-negative, ratio = " & ratio)

  let total = relayRatio + serviceRatio
  if int(total) != 100:
    return err("total ratio should be 100, total = " & $total)

  ok((relayRatio / 100.0, serviceRatio / 100.0))
