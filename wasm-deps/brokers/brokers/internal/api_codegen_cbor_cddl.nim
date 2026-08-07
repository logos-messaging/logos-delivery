## CDDL emission for the CBOR FFI surface.
##
## Walks the per-library `CborRequestEntry` / `CborEventEntry` accumulators
## and the shared `gApiTypeRegistry` to produce a `<lib>.cddl` schema file
## next to the generated C/C++/Python wrappers. The schema is consumable by
## external CDDL tooling (`cddl validate`, `cuddle`, …) and is also embedded
## verbatim in the runtime discovery descriptor returned from
## `<lib>_getSchema`.
##
## CDDL mapping summary:
##   bool                       -> bool
##   int / intN                 -> int
##   uint / uintN / byte        -> uint
##   float / floatN             -> float
##   string / cstring           -> tstr
##   seq[T]                     -> [* T-cddl]
##   array[N, T]                -> [N*N T-cddl]
##   Option[T]                  -> T-cddl / null
##   <registered enum>          -> uint
##   <registered alias/distinct -> resolved underlying type
##   <registered object>        -> rule reference (PascalCase name)
##
## The args type for a request is emitted inline as a synthetic
## `<UpperCamel>Args` rule. The response envelope shape is a single
## reusable rule `BrokerResultEnvelope` parameterised by inlining the
## payload type per request — CDDL has no generics, so we expand it.

{.push raises: [].}

import std/[macros, os, strutils]
import ./api_schema, ./api_common

# ---------------------------------------------------------------------------
# Type-name helpers
# ---------------------------------------------------------------------------

proc upperCamel*(s: string): string {.compileTime.} =
  ## "device_updated" -> "DeviceUpdated"; "GetStatus" stays "GetStatus".
  result = ""
  var capNext = true
  for ch in s:
    if ch == '_' or ch == '-':
      capNext = true
    else:
      if capNext:
        result.add(ch.toUpperAscii())
        capNext = false
      else:
        result.add(ch)

proc stripGenericPrefix(s: string, prefix: string): string {.compileTime.} =
  ## Returns the inner of `prefix[...]`, e.g. `seq[int32]` -> `int32`.
  ## Caller has already verified the prefix.
  let inner = s[prefix.len + 1 .. ^2]
  inner.strip()

proc parseArrayParts(s: string): tuple[size: string, elem: string] {.compileTime.} =
  ## Parse `array[N, T]` into (N, T). Returns ("", "") on malformed input.
  if not s.toLowerAscii().startsWith("array["):
    return ("", "")
  let inner = s[6 .. ^2]
  let comma = inner.find(',')
  if comma < 0:
    return ("", "")
  (inner[0 ..< comma].strip(), inner[comma + 1 .. ^1].strip())

# ---------------------------------------------------------------------------
# Nim type -> CDDL fragment
# ---------------------------------------------------------------------------

proc nimTypeToCddl*(nimType: string): string {.compileTime.} =
  ## Maps a Nim type spelling to a CDDL fragment. Falls back to a rule
  ## reference (the type name itself) for registered objects/enums; the
  ## caller is responsible for emitting that rule elsewhere in the file.
  let t = nimType.strip()
  let lower = t.toLowerAscii()

  case lower
  of "bool":
    return "bool"
  of "string", "cstring":
    return "tstr"
  of "char":
    return "uint .size 1"
  of "int", "int8", "int16", "int32", "int64":
    return "int"
  of "uint", "uint8", "uint16", "uint32", "uint64", "byte":
    return "uint"
  of "float", "float32", "float64":
    return "float"
  else:
    discard

  if lower.startsWith("seq[") and lower.endsWith("]"):
    return "[* " & nimTypeToCddl(stripGenericPrefix(t, "seq")) & "]"

  if lower.startsWith("option[") and lower.endsWith("]"):
    return nimTypeToCddl(stripGenericPrefix(t, "option")) & " / null"

  if lower.startsWith("array["):
    let (sz, elem) = parseArrayParts(t)
    if sz.len > 0 and elem.len > 0:
      return "[" & sz & "*" & sz & " " & nimTypeToCddl(elem) & "]"

  if isAliasOrDistinctRegistered(t):
    return nimTypeToCddl(resolveUnderlyingType(t))

  if isEnumRegistered(t):
    return "uint"

  if isTypeRegistered(t):
    return t

  # Unknown type — emit verbatim and let the CDDL consumer surface the
  # missing rule. This preserves debuggability without aborting codegen
  # for legitimate generic types we haven't taught the mapper about yet.
  t

# ---------------------------------------------------------------------------
# Type-rule emission
# ---------------------------------------------------------------------------

proc emitObjectRule(entry: ApiTypeEntry): string {.compileTime.} =
  result = entry.name & " = {\n"
  for f in entry.fields:
    result.add("  " & f.name & ": " & nimTypeToCddl(f.nimType) & ",\n")
  result.add("}\n")

proc emitEnumRule(entry: ApiTypeEntry): string {.compileTime.} =
  result = "; enum " & entry.name & ":\n"
  for v in entry.enumValues:
    result.add(";   " & v.name & " = " & $v.ordinal & "\n")
  result.add(entry.name & " = uint\n")

proc emitAliasRule(entry: ApiTypeEntry): string {.compileTime.} =
  let kind =
    case entry.kind
    of atkAlias: "alias"
    of atkDistinct: "distinct"
    else: "alias"
  result = "; " & kind & " of " & entry.underlyingType & "\n"
  result.add(entry.name & " = " & nimTypeToCddl(entry.underlyingType) & "\n")

proc emitTypeRule(entry: ApiTypeEntry): string {.compileTime.} =
  case entry.kind
  of atkObject:
    emitObjectRule(entry)
  of atkEnum:
    emitEnumRule(entry)
  of atkAlias, atkDistinct:
    emitAliasRule(entry)

# ---------------------------------------------------------------------------
# Args / envelope rule emission
# ---------------------------------------------------------------------------

proc emitArgsRule(
    ruleName: string, argFields: seq[(string, string)]
): string {.compileTime.} =
  result = ruleName & " = {\n"
  for (fname, ftype) in argFields:
    result.add("  " & fname & ": " & nimTypeToCddl(ftype) & ",\n")
  result.add("}\n")

proc emitEnvelopeRule(ruleName: string, payloadCddl: string): string {.compileTime.} =
  ## CBOR encoding produced by `omitOptionalFields = true`: a map with at
  ## most one of `ok` / `err`, mutually exclusive.
  result = ruleName & " = { ? ok: " & payloadCddl & ", ? err: tstr }\n"

# ---------------------------------------------------------------------------
# File emission
# ---------------------------------------------------------------------------

proc cddlPath(outDir, libName: string): string {.compileTime.} =
  if outDir.len > 0:
    outDir & "/" & libName & ".cddl"
  else:
    libName & ".cddl"

proc generateCborCddl*(
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
    typeRegistry: seq[ApiTypeEntry],
): string {.compileTime.} =
  ## Pure-string assembly so the same blob can be both written to disk and
  ## embedded as a string literal in the generated runtime descriptor.
  result = "; Generated by nim-brokers CBOR FFI codegen for '" & libName & "'.\n"
  result.add("; Do not edit — regenerate by recompiling the library.\n\n")

  result.add("; ----- Shared types ----------------------------------------\n")
  for entry in typeRegistry:
    if entry.name.endsWith("CborArgs"):
      # Synthetic args structs emitted per-request below.
      continue
    result.add(emitTypeRule(entry))
    result.add("\n")

  if requestEntries.len > 0:
    result.add("; ----- Requests --------------------------------------------\n")
    for r in requestEntries:
      let argsRule = upperCamel(r.apiName) & "Args"
      let respEnvRule = upperCamel(r.apiName) & "Response"
      let payloadCddl =
        if r.responseTypeName.len > 0:
          nimTypeToCddl(r.responseTypeName)
        else:
          "{}"

      result.add("; apiName: \"" & r.apiName & "\"\n")
      if r.argFields.len > 0:
        result.add(emitArgsRule(argsRule, r.argFields))
      else:
        result.add(argsRule & " = {}\n")
      result.add(emitEnvelopeRule(respEnvRule, payloadCddl))
      result.add("\n")

  if eventEntries.len > 0:
    result.add("; ----- Events ----------------------------------------------\n")
    for e in eventEntries:
      result.add("; eventName: \"" & e.apiName & "\"\n")
      result.add(
        upperCamel(e.apiName) & "Event = " & nimTypeToCddl(e.typeName) & "\n\n"
      )

proc generateCborCddlFile*(
    outDir: string,
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
    typeRegistry: seq[ApiTypeEntry],
): string {.compileTime, raises: [].} =
  ## Writes `<libName>.cddl` and returns the file's contents so the caller
  ## can embed the same string in the generated runtime discovery payload.
  ensureGeneratedOutputDir(outDir)
  let body = generateCborCddl(libName, requestEntries, eventEntries, typeRegistry)
  let path = cddlPath(outDir, libName)
  try:
    writeFile(path, body)
  except IOError:
    error("Failed to write generated CDDL '" & path & "': " & getCurrentExceptionMsg())
  body

{.pop.}
