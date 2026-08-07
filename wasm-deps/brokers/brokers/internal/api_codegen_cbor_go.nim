## CBOR-mode Go wrapper code generation.
##
## Mirrors `api_codegen_cbor_rust.nim` but emits idiomatic Go with
## `(T, error)` returns. Uses `github.com/fxamacker/cbor/v2` for
## CBOR encoding/decoding (struct tags map Nim camelCase wire keys to
## Go-style PascalCase fields).
##
## Native and CBOR generations write to separate `<outDir>` trees
## (`nimlib/build/` vs `nimlib/build_cbor/`), so each generated module
## directory contains exactly one wrapper. The filename is the same in
## both modes — `<libname>.go` and `<libname>_callbacks.c` — matching
## the C/C++/Rust convention where consumers pick build vs build_cbor
## via their build system, not via build-tag selection inside the
## module.

{.push raises: [].}

import std/[macros, strutils, tables]
import ./api_common, ./api_schema
import ./helper/broker_utils # reduced-A: per-interface partitioning

# ---------------------------------------------------------------------------
# Nim → Go type mapping (registry-aware, used in CBOR mode)
# ---------------------------------------------------------------------------

const goPrimMap = {
  "bool": "bool",
  "string": "string",
  "char": "string",
  "int": "int32",
  "int8": "int8",
  "int16": "int16",
  "int32": "int32",
  "int64": "int64",
  "uint": "uint32",
  "uint8": "uint8",
  "uint16": "uint16",
  "uint32": "uint32",
  "uint64": "uint64",
  "byte": "byte",
  "float": "float64",
  "float32": "float32",
  "float64": "float64",
}.toTable

proc isGoPrimitive(nimType: string): bool {.compileTime.} =
  nimType.strip() in goPrimMap

proc primGoHint(nimType: string): string {.compileTime.} =
  goPrimMap.getOrDefault(nimType.strip(), "")

proc unwrapBracket(s, head: string): string {.compileTime.} =
  let t = s.strip()
  t[head.len + 1 .. ^2].strip()

proc parseArrayInner(s: string): string {.compileTime.} =
  let inner = s.strip()[6 ..^ 2]
  let comma = inner.find(',')
  if comma < 0:
    return ""
  inner[comma + 1 .. ^1].strip()

proc parseTableParams(s: string): (string, string) {.compileTime.} =
  ## "Table[K, V]" -> ("K", "V"); split on the first top-level comma.
  let inner = s.strip()[6 ..^ 2]
  var depth = 0
  for i in 0 ..< inner.len:
    case inner[i]
    of '[', '(':
      inc depth
    of ']', ')':
      dec depth
    of ',':
      if depth == 0:
        return (inner[0 ..< i].strip(), inner[i + 1 .. ^1].strip())
    else:
      discard
  ("", "")

proc nimTypeToGoCborHint*(nimType: string): string {.compileTime.} =
  ## Recursive Nim → Go type for CBOR mode. Returns "" when unmappable.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if isGoPrimitive(t):
    return primGoHint(t)
  if lower.startsWith("table[") and lower.endsWith("]"):
    # Table[K, V] -> map[Kgo]Vgo. Keys ride the wire as CBOR text strings;
    # non-string key fields are converted text <-> typed via generated
    # Marshal/UnmarshalCBOR (see generateCborGoFile). string/char keys map to
    # string and need no conversion.
    let (k, v) = parseTableParams(t)
    let kg = nimTypeToGoCborHint(k)
    let vg = nimTypeToGoCborHint(v)
    return
      if kg.len > 0 and vg.len > 0:
        "map[" & kg & "]" & vg
      else:
        ""
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = nimTypeToGoCborHint(unwrapBracket(t, "seq"))
    return
      if inner.len > 0:
        # Compact CBOR for seq[byte] uses a Go []byte (cbor lib auto-detects).
        "[]" & inner
      else:
        ""
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToGoCborHint(elem)
    return
      if inner.len > 0:
        "[]" & inner
      else:
        ""
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToGoCborHint(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "*" & inner
      else:
        ""
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject, atkEnum:
      return t
    of atkAlias, atkDistinct:
      # Reference the emitted `type <name> = ...` alias BY NAME so fields/params
      # keep the meaningful type (`ContentTopic`, `Timestamp`) instead of
      # flattening to the underlying; "" when it doesn't map.
      if nimTypeToGoCborHint(resolveUnderlyingType(t)).len > 0:
        return t
      return ""
  ""

proc isGoCborMappable*(nimType: string): bool {.compileTime.} =
  nimTypeToGoCborHint(nimType).len > 0

proc goExportedField*(name: string): string {.compileTime.} =
  if name.len > 0 and name[0] >= 'a' and name[0] <= 'z':
    chr(ord(name[0]) - 32) & name[1 ..^ 1]
  else:
    name

proc goTableNeedsKeyConv*(nimType: string): bool {.compileTime.} =
  ## True for a Table[K, V] whose Go key type is not `string` (int / enum /
  ## distinct-of-int). Such fields ride the wire as text-keyed maps and need
  ## conversion in the owning struct's Marshal/UnmarshalCBOR.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if not (lower.startsWith("table[") and lower.endsWith("]")):
    return false
  let (k, _) = parseTableParams(t)
  let kg = nimTypeToGoCborHint(k)
  kg.len > 0 and kg != "string"

proc goTableKeyType*(nimType: string): string {.compileTime.} =
  let (k, _) = parseTableParams(nimType.strip())
  nimTypeToGoCborHint(k)

proc goTableValType*(nimType: string): string {.compileTime.} =
  let (_, v) = parseTableParams(nimType.strip())
  nimTypeToGoCborHint(v)

proc goWireStructField*(f: ApiFieldDef): string {.compileTime.} =
  ## One field line for the string-keyed wire struct used by Marshal/
  ## UnmarshalCBOR — non-string-keyed maps become `map[string]V`.
  let fx = goExportedField(f.name)
  if goTableNeedsKeyConv(f.nimType):
    "\t\t" & fx & " map[string]" & goTableValType(f.nimType) & " `cbor:\"" & f.name &
      "\"`\n"
  else:
    let hint = nimTypeToGoCborHint(f.nimType)
    if hint.len == 0:
      ""
    else:
      "\t\t" & fx & " " & hint & " `cbor:\"" & f.name & "\"`\n"

const goReservedWords = [
  "break", "case", "chan", "const", "continue", "default", "defer", "else",
  "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
  "package", "range", "return", "select", "struct", "switch", "type", "var",
]

proc goSafeParam*(name: string): string {.compileTime.} =
  ## Returns a Go-legal local identifier — appends `Arg` suffix when the
  ## Nim parameter name collides with a Go reserved keyword (e.g.
  ## `range` → `rangeArg`, `type` → `typeArg`). The CBOR wire field is
  ## emitted from the original name, so wire compatibility is preserved.
  if name in goReservedWords:
    name & "Arg"
  else:
    name

proc snakeToPascal(name: string): string {.compileTime.} =
  ## Converts a snake_case identifier (CBOR apiName / event name) to
  ## PascalCase for Go method exports.
  result = ""
  var capitalize = true
  for ch in name:
    if ch == '_' or ch == '-':
      capitalize = true
    elif capitalize:
      result.add(
        if ch >= 'a' and ch <= 'z':
          chr(ord(ch) - 32)
        else:
          ch
      )
      capitalize = false
    else:
      result.add(ch)

proc goCborClassName(libName: string): string {.compileTime.} =
  result = ""
  var capitalize = true
  for ch in libName:
    if ch == '_' or ch == '-':
      capitalize = true
    elif capitalize:
      result.add(chr(ord(ch) - 32 * ord(ch in {'a' .. 'z'})))
      capitalize = false
    else:
      result.add(ch)

proc goCborPackageName(libName: string): string {.compileTime.} =
  result = ""
  for ch in libName:
    if ch != '_' and ch != '-':
      result.add(
        if ch >= 'A' and ch <= 'Z':
          chr(ord(ch) + 32)
        else:
          ch
      )

# ---------------------------------------------------------------------------
# File emission
# ---------------------------------------------------------------------------

{.pop.}

proc goSubStructName(iface: string): string {.compileTime.} =
  ## Wrapper struct name for a sub-interface: strip a leading `I` before an
  ## uppercase letter (IWidget -> Widget), else use the name as-is.
  if iface.len > 1 and iface[0] == 'I' and iface[1] in {'A' .. 'Z'}:
    iface[1 ..^ 1]
  else:
    iface

proc generateCborGoFile*(
    outDir: string,
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
    mainClass: string = "",
    asyncTimeoutMs: int = 30000,
    asyncQueueDepth: int = 64,
    signalEntries: seq[CborSignalEntry] = @[],
) {.compileTime, raises: [].} =
  ## Emits `<outDir>/<libName>_go/{<libName>.go, <libName>_callbacks.c}`.
  ## Same filenames as the native generator — only one wrapper exists per
  ## build dir, so no build tags / no `_cbor` suffix.
  ensureGeneratedOutputDir(outDir)

  # reduced-A: per-interface partition. Sub-interface names derived from the
  # entries via interfaceOwningRequestType (NOT apiInterfaces() — the VM aliases
  # a by-value seq return to an empty copy).
  proc ownsReqMain(e: CborRequestEntry): bool {.compileTime.} =
    if mainClass.len == 0:
      return true
    let o = interfaceOwningRequestType(e.responseTypeName)
    o.len == 0 or o == mainClass

  proc ownsEvtMain(ev: CborEventEntry): bool {.compileTime.} =
    if mainClass.len == 0:
      return true
    let o = interfaceOwningEventType(ev.typeName)
    o.len == 0 or o == mainClass

  proc ownsSigMain(s: CborSignalEntry): bool {.compileTime.} =
    if mainClass.len == 0:
      return true
    let o = interfaceOwningSignalType(s.typeName)
    o.len == 0 or o == mainClass

  var subInterfaceNames: seq[string] = @[]
  if mainClass.len > 0:
    for e in requestEntries:
      let o = interfaceOwningRequestType(e.responseTypeName)
      if o.len > 0 and o != mainClass and o notin subInterfaceNames:
        subInterfaceNames.add(o)
  let modDir =
    if outDir.len > 0:
      outDir & "/" & libName & "_go"
    else:
      libName & "_go"
  ensureGeneratedOutputDir(modDir)

  let pkgName = goCborPackageName(libName)
  let className = goCborClassName(libName)
  let p = libName & "_"

  # ---------------------- go.mod ----------------------
  # Always emit go.mod with the cbor dependency. (If a native-only build
  # ran first and wrote go.mod without it, overwrite.)
  var goMod = "// Generated by nim-brokers Go FFI codegen — do not edit.\n"
  goMod.add("module " & libName & "\n\n")
  goMod.add("go 1.21\n\n")
  goMod.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  try:
    writeFile(modDir & "/go.mod", goMod)
  except IOError:
    error("Failed to write go.mod: " & getCurrentExceptionMsg())

  # ---------------------- <libName>.go ----------------------
  var g = "// Generated by nim-brokers CBOR FFI Go codegen — do not edit.\n"
  g.add("//\n")
  g.add(
    "// CBOR-mode Go wrapper around the fixed 11-fn ABI declared by the `" & libName &
      "` shared library.\n"
  )
  g.add("//\n")
  g.add("// Public surface mirrors the native build:\n")
  g.add("//   " & libName & ".Version()\n")
  g.add("//   " & libName & ".New() + lib.CreateContext()\n")
  g.add("//   <Request>(args) -> (T, error)\n")
  g.add("//   On<Event>(callback) -> uint64 / Off<Event>(handle uint64)\n")
  g.add("//\n")
  for e in requestEntries:
    var sigParams = ""
    for i, (n, t) in e.argFields.pairs:
      if i > 0:
        sigParams.add(", ")
      let h = nimTypeToGoCborHint(t)
      sigParams.add(goExportedField(n) & " " & (if h.len > 0: h else: "any"))
    g.add(
      "//   " & snakeToPascal(e.apiName) & "(" & sigParams & ") (" & e.responseTypeName &
        ", error)\n"
    )
  for ev in eventEntries:
    g.add("//   On" & snakeToPascal(ev.apiName) & "(callback) uint64\n")
    g.add("//   Off" & snakeToPascal(ev.apiName) & "(handle uint64)\n")
  g.add("\n")

  g.add("package " & pkgName & "\n\n")

  # cgo prelude
  g.add("/*\n")
  g.add("#cgo CFLAGS: -I${SRCDIR}/..\n")
  g.add("#cgo LDFLAGS: -L${SRCDIR}/.. -l" & libName & "\n")
  g.add("#cgo darwin LDFLAGS: -Wl,-rpath,${SRCDIR}/..\n")
  g.add("#cgo linux LDFLAGS: -Wl,-rpath,${SRCDIR}/..\n")
  g.add("#include <stdlib.h>\n")
  g.add("#include <string.h>\n")
  g.add("#include <stdint.h>\n")
  g.add("#include \"" & libName & ".h\"\n")
  g.add(
    "uint64_t go_cbor_subscribe(uint32_t ctx, const char* name, void* user_data);\n"
  )
  g.add(
    "int32_t go_cbor_call_async(uint32_t ctx, const char* name, const void* in_buf, int32_t in_len, uint64_t req_id, uint32_t timeout_ms, void* user_data);\n"
  )
  g.add("*/\n")
  g.add("import \"C\"\n\n")

  g.add("import (\n")
  g.add("\t\"context\"\n")
  g.add("\t\"errors\"\n")
  g.add("\t\"fmt\"\n")
  g.add("\t\"runtime\"\n")
  g.add("\t\"runtime/cgo\"\n")
  g.add("\t\"strconv\"\n")
  g.add("\t\"sync\"\n")
  g.add("\t\"time\"\n")
  g.add("\t\"unsafe\"\n")
  g.add("\t\"github.com/fxamacker/cbor/v2\"\n")
  g.add(")\n\n")
  g.add("var _ = context.Background\n")
  g.add("var _ = errors.New\n")
  g.add("var _ = time.Until\n")
  g.add("var _ = fmt.Errorf\n")
  g.add("var _ = runtime.SetFinalizer\n")
  g.add("var _ = strconv.Itoa\n")
  g.add("var _ cgo.Handle\n")
  g.add("var _ sync.Mutex\n")
  g.add("var _ unsafe.Pointer\n")
  g.add("var _ = cbor.Marshal\n\n")

  # Per-context cgo.Handle registry — same UAF-safe pattern as native:
  # the closure stays alive across Off<Event> until Close() runs.
  g.add("var cborHandleReg = struct {\n")
  g.add("\tmu sync.Mutex\n")
  g.add("\tperCtx map[uint32][]cgo.Handle\n")
  g.add("}{perCtx: make(map[uint32][]cgo.Handle)}\n\n")
  g.add("func registerCborHandle(ctx C.uint32_t, h cgo.Handle) {\n")
  g.add("\tcborHandleReg.mu.Lock()\n")
  g.add(
    "\tcborHandleReg.perCtx[uint32(ctx)] = append(cborHandleReg.perCtx[uint32(ctx)], h)\n"
  )
  g.add("\tcborHandleReg.mu.Unlock()\n")
  g.add("}\n\n")
  g.add("func dropCborHandlesForCtx(ctx C.uint32_t) {\n")
  g.add("\tcborHandleReg.mu.Lock()\n")
  g.add("\thandles := cborHandleReg.perCtx[uint32(ctx)]\n")
  g.add("\tdelete(cborHandleReg.perCtx, uint32(ctx))\n")
  g.add("\tcborHandleReg.mu.Unlock()\n")
  g.add("\tfor _, h := range handles { h.Delete() }\n")
  g.add("}\n\n")

  # ---- Generated payload types ------------------------------------------
  var enumNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind == atkEnum:
      enumNames.add(entry.name)
  var aliasNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind in {atkDistinct, atkAlias}:
      aliasNames.add(entry.name)
  var objectNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind == atkObject and not entry.name.endsWith("CborArgs"):
      objectNames.add(entry.name)

  # A "scalar payload" is a primitive (non-object) broker type — `type X =
  # int32` — registered as a distinct alias of its underlying primitive.
  # Its CBOR wire value is a bare scalar; the Go surface uses the
  # `type X = <prim>` alias directly. Such a type has no object fields, so
  # the event handler delivers the bare value rather than unpacked fields.
  # Full mapper (not just primGoHint) so a container payload (`seq[string]`
  # -> []string) is an emittable scalar payload, not only primitives.
  proc isScalarPayload(name: string): bool {.compileTime.} =
    name.len > 0 and isTypeRegistered(name) and
      lookupTypeEntry(name).kind in {atkAlias, atkDistinct} and
      nimTypeToGoCborHint(resolveUnderlyingType(name)).len > 0

  if enumNames.len > 0 or aliasNames.len > 0 or objectNames.len > 0:
    g.add("// -------- Generated payload types --------\n\n")

  for name in enumNames:
    let entry = lookupTypeEntry(name)
    g.add("type " & name & " int32\n\n")
    g.add("const (\n")
    if entry.enumValues.len == 0:
      g.add("\t" & name & "_Unknown " & name & " = 0\n")
    else:
      for v in entry.enumValues:
        g.add("\t" & name & "_" & v.name & " " & name & " = " & $v.ordinal & "\n")
    g.add(")\n\n")

  # A bare-primitive response payload is unwrapped to the simple type, so its
  # synthetic `type Verb = bool` alias is dead — skip it. Field-used aliases
  # (`ContentTopic`) are never response names, so they stay.
  var responseNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len > 0 and e.responseTypeName notin responseNames:
      responseNames.add(e.responseTypeName)
  for name in aliasNames:
    if name in responseNames and effectiveResponsePayload(name) != name:
      continue
    let underlying = resolveUnderlyingType(name)
    let goU = nimTypeToGoCborHint(underlying)
    if goU.len == 0:
      g.add(
        "// TODO: alias '" & name & "' resolves to '" & underlying &
          "' (no Go mapping)\n\n"
      )
      continue
    g.add("type " & name & " = " & goU & "\n\n")

  for name in objectNames:
    let entry = lookupTypeEntry(name)
    g.add("type " & name & " struct {\n")
    var anyField = false
    for f in entry.fields:
      let hint = nimTypeToGoCborHint(f.nimType)
      if hint.len == 0:
        g.add("\t// TODO: Nim type '" & f.nimType & "' not yet mappable\n")
        continue
      let fx = goExportedField(f.name)
      g.add("\t" & fx & " " & hint & " `cbor:\"" & f.name & "\"`\n")
      anyField = true
    if not anyField:
      g.add("\t_ struct{}\n")
    g.add("}\n\n")

    # When a field is a non-string-keyed Table, fxamacker cannot decode the
    # text-keyed wire map into the typed-key Go map (it silently drops the
    # entries). Emit Marshal/UnmarshalCBOR that round-trip through a
    # string-keyed wire struct, converting keys via strconv. int / enum /
    # distinct-of-int keys all convert through int64.
    var hasConv = false
    for f in entry.fields:
      if goTableNeedsKeyConv(f.nimType):
        hasConv = true
    if hasConv:
      g.add("func (s " & name & ") MarshalCBOR() ([]byte, error) {\n")
      g.add("\ttype wire struct {\n")
      for f in entry.fields:
        g.add(goWireStructField(f))
      g.add("\t}\n\tvar w wire\n")
      for f in entry.fields:
        if nimTypeToGoCborHint(f.nimType).len == 0:
          continue
        let fx = goExportedField(f.name)
        if goTableNeedsKeyConv(f.nimType):
          let vt = goTableValType(f.nimType)
          g.add("\tw." & fx & " = make(map[string]" & vt & ", len(s." & fx & "))\n")
          g.add(
            "\tfor k, v := range s." & fx & " { w." & fx &
              "[strconv.FormatInt(int64(k), 10)] = v }\n"
          )
        else:
          g.add("\tw." & fx & " = s." & fx & "\n")
      g.add("\treturn cbor.Marshal(w)\n}\n\n")

      g.add("func (s *" & name & ") UnmarshalCBOR(data []byte) error {\n")
      g.add("\ttype wire struct {\n")
      for f in entry.fields:
        g.add(goWireStructField(f))
      g.add("\t}\n\tvar w wire\n")
      g.add("\tif err := cbor.Unmarshal(data, &w); err != nil {\n\t\treturn err\n\t}\n")
      for f in entry.fields:
        if nimTypeToGoCborHint(f.nimType).len == 0:
          continue
        let fx = goExportedField(f.name)
        if goTableNeedsKeyConv(f.nimType):
          let kt = goTableKeyType(f.nimType)
          let vt = goTableValType(f.nimType)
          g.add("\ts." & fx & " = make(map[" & kt & "]" & vt & ", len(w." & fx & "))\n")
          g.add("\tfor k, v := range w." & fx & " {\n")
          g.add("\t\tn, err := strconv.ParseInt(k, 10, 64)\n")
          g.add("\t\tif err != nil {\n\t\t\treturn err\n\t\t}\n")
          g.add("\t\ts." & fx & "[" & kt & "(n)] = v\n\t}\n")
        else:
          g.add("\ts." & fx & " = w." & fx & "\n")
      g.add("\treturn nil\n}\n\n")

  # ---- Lib struct + event handler type -----------------------------------
  g.add("// -------- Event dispatch --------\n\n")
  g.add("// cborEventHandler is what we anchor on the Go side via cgo.NewHandle.\n")
  g.add("// Each subscription's user_data is the corresponding cgo.Handle, so\n")
  g.add("// the trampoline retrieves and invokes exactly that one closure per\n")
  g.add("// event emit — no global map, no fan-out, no cross-context leakage.\n")
  g.add("type cborEventHandler func([]byte)\n\n")

  g.add("// -------- Lib struct --------\n\n")
  g.add("type " & className & " struct {\n")
  g.add("\tctx C.uint32_t\n")
  g.add("\tmu  sync.Mutex\n")
  g.add("}\n\n")

  g.add("func Version() string {\n")
  g.add("\treturn C.GoString(C." & p & "version())\n")
  g.add("}\n\n")

  g.add("func New() *" & className & " {\n")
  g.add("\tC." & p & "initialize()\n")
  g.add("\tl := &" & className & "{}\n")
  g.add("\truntime.SetFinalizer(l, func(x *" & className & ") { x.Close() })\n")
  g.add("\treturn l\n")
  g.add("}\n\n")

  g.add("func (l *" & className & ") CreateContext() error {\n")
  g.add("\tl.mu.Lock()\n\tdefer l.mu.Unlock()\n")
  g.add("\tif l.ctx != 0 { return errors.New(\"context already created\") }\n")
  g.add("\tvar errPtr *C.char\n")
  g.add("\tctx := C." & p & "createContext(&errPtr)\n")
  g.add("\tif ctx == 0 {\n")
  g.add("\t\tmsg := \"createContext returned 0\"\n")
  g.add(
    "\t\tif errPtr != nil { msg = C.GoString(errPtr); C." & p &
      "freeBuffer(unsafe.Pointer(errPtr)) }\n"
  )
  g.add("\t\treturn errors.New(msg)\n")
  g.add("\t}\n")
  g.add("\tl.ctx = ctx\n")
  g.add("\treturn nil\n")
  g.add("}\n\n")

  g.add("func (l *" & className & ") ValidContext() bool { return l.ctx != 0 }\n")
  g.add("func (l *" & className & ") Ctx() uint32 { return uint32(l.ctx) }\n\n")

  g.add("func (l *" & className & ") Close() {\n")
  g.add("\tl.mu.Lock()\n\tdefer l.mu.Unlock()\n")
  g.add("\tif l.ctx != 0 {\n")
  g.add("\t\tC." & p & "shutdown(l.ctx)\n")
  g.add("\t\tdropCborHandlesForCtx(l.ctx)\n")
  g.add("\t\tl.ctx = 0\n")
  g.add("\t}\n")
  g.add("}\n\n")

  # ---- Internal call helper ----------------------------------------------
  g.add("// internalCborCall encodes args via CBOR, copies into a library-\n")
  g.add("// allocated buffer (the C ABI frees it), dispatches, and returns\n")
  g.add("// the response bytes (caller-side copy of a library-owned buffer).\n")
  g.add(
    "func (l *" & className &
      ") internalCborCall(apiName string, args interface{}) ([]byte, error) {\n"
  )
  g.add(
    "\tif l.ctx == 0 { return nil, errors.New(\"library context is not created\") }\n"
  )
  g.add("\tvar inBytes []byte\n")
  g.add("\tif args != nil {\n")
  g.add("\t\tvar err error\n")
  g.add("\t\tinBytes, err = cbor.Marshal(args)\n")
  g.add("\t\tif err != nil { return nil, err }\n")
  g.add("\t}\n")
  g.add("\tcName := C.CString(apiName)\n")
  g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
  g.add("\t// The library expects an `<lib>_allocBuffer`-allocated input\n")
  g.add("\t// buffer that it can free. Copy the Go bytes into one.\n")
  g.add("\tvar inPtr unsafe.Pointer\n")
  g.add("\tif len(inBytes) > 0 {\n")
  g.add("\t\tinPtr = C." & p & "allocBuffer(C.int32_t(len(inBytes)))\n")
  g.add("\t\tif inPtr == nil { return nil, errors.New(\"allocBuffer failed\") }\n")
  g.add("\t\tC.memcpy(inPtr, unsafe.Pointer(&inBytes[0]), C.size_t(len(inBytes)))\n")
  g.add("\t}\n")
  g.add("\tvar outBuf unsafe.Pointer\n")
  g.add("\tvar outLen C.int32_t\n")
  g.add(
    "\trc := C." & p &
      "call(l.ctx, cName, inPtr, C.int32_t(len(inBytes)), &outBuf, &outLen)\n"
  )
  g.add("\tif rc != 0 {\n")
  g.add("\t\tif outBuf != nil { C." & p & "freeBuffer(outBuf) }\n")
  g.add("\t\treturn nil, errors.New(\"call returned non-zero\")\n")
  g.add("\t}\n")
  g.add("\tif outBuf == nil { return nil, nil }\n")
  g.add("\tout := C.GoBytes(outBuf, C.int(outLen))\n")
  g.add("\tC." & p & "freeBuffer(outBuf)\n")
  g.add("\treturn out, nil\n")
  g.add("}\n\n")

  # signalCall: slot-free one-way dispatch through `_call`. No response; status
  # maps to nil (accepted) or a distinguishable error. Emitted for the main class
  # and for each sub-interface that owns a signal (both keyed by l.ctx, so a
  # sub-interface signal routes to that sub-instance's ctx).
  proc emitGoSignalCall(recv: string): string {.compileTime.} =
    result.add("// signalCall dispatches a one-way signal (no response envelope).\n")
    result.add(
      "func (l *" & recv & ") signalCall(apiName string, args interface{}) error {\n"
    )
    result.add(
      "\tif l.ctx == 0 { return errors.New(\"library context is not created\") }\n"
    )
    result.add("\tvar inBytes []byte\n")
    result.add("\tif args != nil {\n")
    result.add("\t\tvar err error\n")
    result.add("\t\tinBytes, err = cbor.Marshal(args)\n")
    result.add("\t\tif err != nil { return err }\n")
    result.add("\t}\n")
    result.add("\tcName := C.CString(apiName)\n")
    result.add("\tdefer C.free(unsafe.Pointer(cName))\n")
    result.add("\tvar inPtr unsafe.Pointer\n")
    result.add("\tif len(inBytes) > 0 {\n")
    result.add("\t\tinPtr = C." & p & "allocBuffer(C.int32_t(len(inBytes)))\n")
    result.add("\t\tif inPtr == nil { return errors.New(\"allocBuffer failed\") }\n")
    result.add(
      "\t\tC.memcpy(inPtr, unsafe.Pointer(&inBytes[0]), C.size_t(len(inBytes)))\n"
    )
    result.add("\t}\n")
    result.add("\tvar outBuf unsafe.Pointer\n")
    result.add("\tvar outLen C.int32_t\n")
    result.add(
      "\trc := C." & p &
        "call(l.ctx, cName, inPtr, C.int32_t(len(inBytes)), &outBuf, &outLen)\n"
    )
    result.add("\tif outBuf != nil { C." & p & "freeBuffer(outBuf) }\n")
    result.add("\tswitch int32(rc) {\n")
    result.add("\tcase 0:\n\t\treturn nil\n")
    result.add(
      "\tcase " & $ApiStatusAgain &
        ":\n\t\treturn errors.New(\"EAGAIN: signal queue full\")\n"
    )
    result.add(
      "\tcase " & $ApiStatusProviderErr &
        ":\n\t\treturn errors.New(\"no signal handler installed\")\n"
    )
    result.add("\tdefault:\n\t\treturn fmt.Errorf(\"signal failed: %d\", int32(rc))\n")
    result.add("\t}\n")
    result.add("}\n\n")

  g.add(emitGoSignalCall(className))

  # ---- Async request plumbing (goroutine + channel per call) --------------
  g.add("// AsyncQueueDepth is the max concurrent in-flight <Method>Async calls\n")
  g.add("// per context; a full window makes <Method>Async return ErrAsyncAgain.\n")
  g.add("const AsyncQueueDepth = " & $asyncQueueDepth & "\n")
  g.add("// DefaultAsyncTimeoutMs is the library default dispatch timeout applied\n")
  g.add("// by <Method>Async (0 would mean infinite).\n")
  g.add("const DefaultAsyncTimeoutMs = " & $asyncTimeoutMs & "\n\n")
  g.add(
    "// ErrAsyncAgain is returned by <Method>Async when the async window is full.\n"
  )
  g.add("var ErrAsyncAgain = errors.New(\"EAGAIN: async window full\")\n\n")
  g.add("// cborAsyncRaw carries one raw response from the trampoline to the\n")
  g.add("// per-call goroutine, which decodes it into the typed <Method>Result.\n")
  g.add("type cborAsyncRaw struct {\n")
  g.add("\tstatus  int32\n")
  g.add("\tpayload []byte\n")
  g.add("}\n\n")
  g.add("func asyncStatusError(status int32, payload []byte) error {\n")
  g.add("\tswitch {\n")
  g.add("\tcase status == " & $ApiStatusUnknownApi & " && len(payload) > 0:\n")
  g.add("\t\treturn errors.New(string(payload))\n")
  g.add("\tcase status == " & $ApiStatusTimeout & ":\n")
  g.add("\t\treturn errors.New(\"request timed out\")\n")
  g.add("\tcase status == " & $ApiStatusShutdown & ":\n")
  g.add("\t\treturn errors.New(\"library shut down\")\n")
  g.add("\tdefault:\n")
  g.add("\t\treturn fmt.Errorf(\"framework error: %d\", status)\n")
  g.add("\t}\n")
  g.add("}\n\n")
  g.add("// goCborResponseTrampoline runs on the library's delivery thread: it\n")
  g.add("// reconstructs the per-call channel (the opaque user_data cgo.Handle),\n")
  g.add("// hands over the raw (status, payload), then frees the handle.\n")
  g.add("//export goCborResponseTrampoline\n")
  g.add(
    "func goCborResponseTrampoline(ud unsafe.Pointer, reqId C.uint64_t, status C.int32_t, respBuf unsafe.Pointer, respLen C.int32_t) {\n"
  )
  g.add("\t_ = reqId\n")
  g.add("\tif ud == nil { return }\n")
  g.add("\th := cgo.Handle(uintptr(ud))\n")
  g.add("\tch, ok := h.Value().(chan cborAsyncRaw)\n")
  g.add("\th.Delete()\n")
  g.add("\tif !ok { return }\n")
  g.add("\tvar payload []byte\n")
  g.add("\tif respBuf != nil && respLen > 0 {\n")
  g.add("\t\tpayload = C.GoBytes(respBuf, C.int(respLen))\n")
  g.add("\t}\n")
  g.add("\tch <- cborAsyncRaw{status: int32(status), payload: payload}\n")
  g.add("}\n\n")

  # ---- Per-request methods ------------------------------------------------
  # Factored emitters reused by the main Lib and each sub-interface struct.
  proc emitGoReqMethod(e: CborRequestEntry, recv: string): string {.compileTime.} =
    let methodName = snakeToPascal(e.apiName)
    # A synthetic proc-sugar payload surfaces its real type: the named alias
    # (`(RequestId, error)`), the bare primitive (`(bool, error)`), or the
    # synthetic name for an anonymous container (`(ConnectedPeers, error)`).
    let resp = effectiveResponsePayload(e.responseTypeName)
    let respType =
      if isNimPrimitive(resp):
        primGoHint(resp)
      else:
        resp
    var argsStructFields = ""
    var argsAssign = ""
    var firstNonZero = false
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      let exN = goExportedField(n)
      argsStructFields.add("\t\t" & exN & " " & hType & " `cbor:\"" & n & "\"`\n")
      argsAssign.add("\t\t" & exN & ": " & goSafeParam(n) & ",\n")
      firstNonZero = true
    result.add("func (l *" & recv & ") " & methodName & "(")
    var firstP = true
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      if not firstP:
        result.add(", ")
      result.add(goSafeParam(n) & " " & hType)
      firstP = false
    result.add(") (" & respType & ", error) {\n")
    result.add("\tvar zeroResp " & respType & "\n")
    if firstNonZero:
      result.add("\targs := struct {\n")
      result.add(argsStructFields)
      result.add("\t}{\n")
      result.add(argsAssign)
      result.add("\t}\n")
      result.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", args)\n")
    else:
      result.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", nil)\n")
    result.add("\tif err != nil { return zeroResp, err }\n")
    result.add("\tvar env struct {\n")
    result.add("\t\tOk  *" & respType & " `cbor:\"ok\"`\n")
    result.add("\t\tErr *string `cbor:\"err\"`\n")
    result.add("\t}\n")
    result.add(
      "\tif derr := cbor.Unmarshal(out, &env); derr != nil { return zeroResp, derr }\n"
    )
    result.add("\tif env.Err != nil { return zeroResp, errors.New(*env.Err) }\n")
    result.add("\tif env.Ok != nil { return *env.Ok, nil }\n")
    result.add("\treturn zeroResp, errors.New(\"empty response envelope\")\n")
    result.add("}\n\n")

  # Context sibling (database/sql `QueryContext` idiom): a BLOCKING, ctx-aware
  # call riding the async ABI. `ctx.Deadline()` maps to the ABI `timeoutMs`
  # (no deadline → library default); `ctx.Done()` returns `ctx.Err()` early.
  # Fan-out is the caller's goroutines — no per-call goroutine or typed channel
  # is spawned here; the C response callback fulfils the buffered raw chan and
  # the caller's goroutine decodes inline. Abandonment on ctx-cancel is
  # leak-free: the trampoline owns the cgo.Handle deletion and the raw chan is
  # buffered (cap 1), so the late send never blocks and the chan is GC'd.
  # NOTE: ctx cancellation cannot stop the Nim-side request (no cancel ABI);
  # the in-flight slot is reclaimed when the response or library timeout fires.
  proc emitGoContextMethod(e: CborRequestEntry, recv: string): string {.compileTime.} =
    let methodName = snakeToPascal(e.apiName)
    let resp = effectiveResponsePayload(e.responseTypeName)
    let respType =
      if isNimPrimitive(resp):
        primGoHint(resp)
      else:
        resp
    var argsStructFields = ""
    var argsAssign = ""
    var firstNonZero = false
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      let exN = goExportedField(n)
      argsStructFields.add("\t\t" & exN & " " & hType & " `cbor:\"" & n & "\"`\n")
      argsAssign.add("\t\t" & exN & ": " & goSafeParam(n) & ",\n")
      firstNonZero = true
    result.add("func (l *" & recv & ") " & methodName & "Context(ctx context.Context")
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      result.add(", " & goSafeParam(n) & " " & hType)
    result.add(") (" & respType & ", error) {\n")
    result.add("\tvar zeroResp " & respType & "\n")
    result.add(
      "\tif l.ctx == 0 { return zeroResp, errors.New(\"library context is not created\") }\n"
    )
    result.add("\tif ctx == nil {\n")
    result.add("\t\tctx = context.Background()\n")
    result.add("\t}\n")
    result.add("\t// ctx deadline -> ABI timeoutMs; no deadline -> library default.\n")
    result.add("\ttimeoutMs := uint32(DefaultAsyncTimeoutMs)\n")
    result.add("\tif d, ok := ctx.Deadline(); ok {\n")
    result.add("\t\tremaining := time.Until(d)\n")
    result.add("\t\tif remaining <= 0 { return zeroResp, context.DeadlineExceeded }\n")
    result.add("\t\tms := remaining.Milliseconds()\n")
    result.add("\t\tif ms < 1 {\n")
    result.add("\t\t\tms = 1\n")
    result.add("\t\t}\n")
    result.add("\t\ttimeoutMs = uint32(ms)\n")
    result.add("\t}\n")
    if firstNonZero:
      result.add("\targs := struct {\n")
      result.add(argsStructFields)
      result.add("\t}{\n")
      result.add(argsAssign)
      result.add("\t}\n")
      result.add("\tinBytes, merr := cbor.Marshal(args)\n")
      result.add("\tif merr != nil { return zeroResp, merr }\n")
    else:
      result.add("\tvar inBytes []byte\n")
    result.add("\tcName := C.CString(\"" & e.apiName & "\")\n")
    result.add("\tdefer C.free(unsafe.Pointer(cName))\n")
    result.add("\tvar inPtr unsafe.Pointer\n")
    result.add("\tif len(inBytes) > 0 {\n")
    result.add("\t\tinPtr = C." & p & "allocBuffer(C.int32_t(len(inBytes)))\n")
    result.add(
      "\t\tif inPtr == nil { return zeroResp, errors.New(\"allocBuffer failed\") }\n"
    )
    result.add(
      "\t\tC.memcpy(inPtr, unsafe.Pointer(&inBytes[0]), C.size_t(len(inBytes)))\n"
    )
    result.add("\t}\n")
    result.add("\trawCh := make(chan cborAsyncRaw, 1)\n")
    result.add("\th := cgo.NewHandle(rawCh)\n")
    result.add(
      "\trc := int32(C.go_cbor_call_async(l.ctx, cName, inPtr, C.int32_t(len(inBytes)), 0, C.uint32_t(timeoutMs), unsafe.Pointer(h)))\n"
    )
    result.add("\tif rc != 0 {\n")
    result.add("\t\th.Delete()\n")
    result.add(
      "\t\tif rc == " & $ApiStatusAgain & " { return zeroResp, ErrAsyncAgain }\n"
    )
    result.add("\t\treturn zeroResp, fmt.Errorf(\"framework error: %d\", rc)\n")
    result.add("\t}\n")
    result.add("\tselect {\n")
    result.add("\tcase <-ctx.Done():\n")
    result.add("\t\t// The Nim-side request keeps running (no cancel ABI); its slot\n")
    result.add("\t\t// frees on response/timeout. The late trampoline send hits the\n")
    result.add("\t\t// buffered chan and the whole thing is GC'd — leak-free.\n")
    result.add("\t\treturn zeroResp, ctx.Err()\n")
    result.add("\tcase raw := <-rawCh:\n")
    result.add("\t\tif raw.status != 0 {\n")
    result.add("\t\t\treturn zeroResp, asyncStatusError(raw.status, raw.payload)\n")
    result.add("\t\t}\n")
    result.add("\t\tvar env struct {\n")
    result.add("\t\t\tOk  *" & respType & " `cbor:\"ok\"`\n")
    result.add("\t\t\tErr *string `cbor:\"err\"`\n")
    result.add("\t\t}\n")
    result.add("\t\tif derr := cbor.Unmarshal(raw.payload, &env); derr != nil {\n")
    result.add("\t\t\treturn zeroResp, derr\n")
    result.add("\t\t}\n")
    result.add("\t\tif env.Err != nil {\n")
    result.add("\t\t\treturn zeroResp, errors.New(*env.Err)\n")
    result.add("\t\t}\n")
    result.add("\t\tif env.Ok != nil {\n")
    result.add("\t\t\treturn *env.Ok, nil\n")
    result.add("\t\t}\n")
    result.add("\t\treturn zeroResp, errors.New(\"empty response envelope\")\n")
    result.add("\t}\n")
    result.add("}\n\n")

  # reduced-A: a create-instance method returns the typed sub-wrapper. The wire
  # ok value is a bare uint32 ctx; build &Sub{ctx} from it + a finalizer backstop.
  proc emitGoInstanceMethod(e: CborRequestEntry, recv: string): string {.compileTime.} =
    let methodName = snakeToPascal(e.apiName)
    let sub = goSubStructName(e.returnsInterface)
    var argsStructFields = ""
    var argsAssign = ""
    var firstNonZero = false
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      let exN = goExportedField(n)
      argsStructFields.add("\t\t" & exN & " " & hType & " `cbor:\"" & n & "\"`\n")
      argsAssign.add("\t\t" & exN & ": " & goSafeParam(n) & ",\n")
      firstNonZero = true
    result.add("func (l *" & recv & ") " & methodName & "(")
    var firstP = true
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      if not firstP:
        result.add(", ")
      result.add(goSafeParam(n) & " " & hType)
      firstP = false
    result.add(") (*" & sub & ", error) {\n")
    if firstNonZero:
      result.add("\targs := struct {\n")
      result.add(argsStructFields)
      result.add("\t}{\n")
      result.add(argsAssign)
      result.add("\t}\n")
      result.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", args)\n")
    else:
      result.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", nil)\n")
    result.add("\tif err != nil { return nil, err }\n")
    result.add("\tvar env struct {\n")
    result.add("\t\tOk  *uint32 `cbor:\"ok\"`\n")
    result.add("\t\tErr *string `cbor:\"err\"`\n")
    result.add("\t}\n")
    result.add(
      "\tif derr := cbor.Unmarshal(out, &env); derr != nil { return nil, derr }\n"
    )
    result.add("\tif env.Err != nil { return nil, errors.New(*env.Err) }\n")
    result.add(
      "\tif env.Ok == nil { return nil, errors.New(\"empty response envelope\") }\n"
    )
    result.add("\tw := &" & sub & "{ctx: C.uint32_t(*env.Ok)}\n")
    result.add("\truntime.SetFinalizer(w, func(x *" & sub & ") { x.Close() })\n")
    result.add("\treturn w, nil\n")
    result.add("}\n\n")

  for e in requestEntries:
    if not ownsReqMain(e):
      continue
    if e.returnsInterface.len > 0:
      g.add(emitGoInstanceMethod(e, className))
    else:
      g.add(emitGoReqMethod(e, className))
      g.add(emitGoContextMethod(e, className))

  # ---- Per-signal one-way methods: `func (l *Lib) <Name>(fields...) error` --
  proc emitGoSignalMethod(s: CborSignalEntry, recv: string): string {.compileTime.} =
    if not (s.typeName in objectNames or isScalarPayload(s.typeName)):
      return
        "// TODO: signal '" & s.apiName & "' payload '" & s.typeName &
        "' is not a registered type.\n\n"
    var fields: seq[ApiFieldDef]
    if s.typeName in objectNames:
      fields = lookupTypeEntry(s.typeName).fields
    else:
      fields = @[ApiFieldDef(name: "value", nimType: resolveUnderlyingType(s.typeName))]
    for f in fields:
      if nimTypeToGoCborHint(f.nimType).len == 0:
        return
          "// TODO: signal '" & s.apiName &
          "' has fields whose Nim types aren't yet mappable to Go.\n\n"
    let methodName = snakeToPascal(s.apiName)
    var sigParams = ""
    var first = true
    for f in fields:
      if not first:
        sigParams.add(", ")
      sigParams.add(goSafeParam(f.name) & " " & nimTypeToGoCborHint(f.nimType))
      first = false
    result.add("func (l *" & recv & ") " & methodName & "(" & sigParams & ") error {\n")
    if fields.len == 0:
      result.add("\treturn l.signalCall(\"" & s.apiName & "\", nil)\n")
    elif s.typeName in objectNames:
      result.add("\targs := struct {\n")
      for f in fields:
        result.add(
          "\t\t" & goExportedField(f.name) & " " & nimTypeToGoCborHint(f.nimType) &
            " `cbor:\"" & f.name & "\"`\n"
        )
      result.add("\t}{\n")
      for f in fields:
        result.add(
          "\t\t" & goExportedField(f.name) & ": " & goSafeParam(f.name) & ",\n"
        )
      result.add("\t}\n")
      result.add("\treturn l.signalCall(\"" & s.apiName & "\", args)\n")
    else:
      result.add(
        "\treturn l.signalCall(\"" & s.apiName & "\", " & goSafeParam(fields[0].name) &
          ")\n"
      )
    result.add("}\n\n")

  for s in signalEntries:
    if not ownsSigMain(s):
      continue
    g.add(emitGoSignalMethod(s, className))

  # ---- Single CBOR event trampoline + per-event On/Off ---------------------
  if eventEntries.len > 0:
    g.add("// -------- CBOR event trampoline --------\n\n")
    g.add("//export goCborEventTrampoline\n")
    g.add(
      "func goCborEventTrampoline(ctx C.uint32_t, name *C.char, buf unsafe.Pointer, bufLen C.int32_t, ud unsafe.Pointer) {\n"
    )
    g.add("\t_ = ctx\n")
    g.add("\t_ = name\n")
    g.add("\tif ud == nil { return }\n")
    g.add("\tvar payload []byte\n")
    g.add("\tif buf != nil && bufLen > 0 {\n")
    g.add("\t\tpayload = C.GoBytes(buf, C.int(bufLen))\n")
    g.add("\t}\n")
    g.add("\th := cgo.Handle(uintptr(ud))\n")
    g.add("\tcb, ok := h.Value().(cborEventHandler)\n")
    g.add("\tif !ok { return }\n")
    g.add("\tcb(payload)\n")
    g.add("}\n\n")

  for ev in eventEntries:
    if not ownsEvtMain(ev):
      continue
    let exName = snakeToPascal(ev.apiName)
    let payloadType = ev.typeName
    # Walk the payload struct fields to build an unpacked-field handler
    # signature that matches the native build's `func(f1, f2, ...)` shape.
    var fieldNames: seq[string] = @[]
    var fieldGoTypes: seq[string] = @[]
    var fieldExNames: seq[string] = @[]
    var fieldsOk = true
    let scalarEvt = isScalarPayload(payloadType)
    if scalarEvt:
      # Scalar payload: the decoded `p` IS the value — one bare arg.
      fieldNames.add("value")
      fieldGoTypes.add(primGoHint(resolveUnderlyingType(payloadType)))
      fieldExNames.add("value")
    elif isTypeRegistered(payloadType):
      let entry = lookupTypeEntry(payloadType)
      for f in entry.fields:
        let h = nimTypeToGoCborHint(f.nimType)
        if h.len == 0:
          fieldsOk = false
          break
        fieldNames.add(f.name)
        fieldGoTypes.add(h)
        fieldExNames.add(goExportedField(f.name))
    else:
      fieldsOk = false

    if not fieldsOk:
      # Fall back to whole-struct callback if the payload has unmappable
      # fields (no native equivalent — both modes share the same gap).
      g.add(
        "// TODO(go-codegen-cbor): event '" & payloadType &
          "' has fields not yet mappable\n"
      )
      g.add(
        "func (l *" & className & ") On" & exName & "(cb func(" & payloadType &
          ")) uint64 { _ = cb; return 0 }\n\n"
      )
    else:
      var sig = ""
      for i in 0 ..< fieldNames.len:
        if i > 0:
          sig.add(", ")
        sig.add(fieldNames[i] & " " & fieldGoTypes[i])
      g.add(
        "func (l *" & className & ") On" & exName & "(cb func(" & sig & ")) uint64 {\n"
      )
      g.add("\tif l.ctx == 0 { return 0 }\n")
      g.add("\twrap := cborEventHandler(func(payload []byte) {\n")
      g.add("\t\tvar p " & payloadType & "\n")
      g.add("\t\tif derr := cbor.Unmarshal(payload, &p); derr != nil { return }\n")
      g.add("\t\tcb(")
      if scalarEvt:
        # Scalar payload: `p` IS the value — pass it directly.
        g.add("p")
      else:
        for i in 0 ..< fieldNames.len:
          if i > 0:
            g.add(", ")
          g.add("p." & fieldExNames[i])
      g.add(")\n")
      g.add("\t})\n")
      g.add("\th := cgo.NewHandle(wrap)\n")
      g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
      g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
      g.add(
        "\thandle := uint64(C.go_cbor_subscribe(l.ctx, cName, unsafe.Pointer(h)))\n"
      )
      g.add("\tif handle == 0 {\n")
      g.add("\t\th.Delete()\n")
      g.add("\t\treturn 0\n")
      g.add("\t}\n")
      g.add("\tregisterCborHandle(l.ctx, h)\n")
      g.add("\treturn handle\n")
      g.add("}\n\n")

    g.add("func (l *" & className & ") Off" & exName & "(handle uint64) {\n")
    g.add("\tif l.ctx == 0 { return }\n")
    g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
    g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
    g.add("\tC." & p & "unsubscribe(l.ctx, cName, C.uint64_t(handle))\n")
    g.add("}\n\n")

  # reduced-A: sub-interface wrapper structs. Each shares the single C ABI: its
  # methods call C.<lib>_call(ctx, ...) which the library routes by classCtx to
  # the same processing thread. Close() (+ finalizer backstop) calls
  # C.<lib>_releaseInstance, after which the Nim instance is GC-reclaimed.
  for ifaceName in subInterfaceNames:
    let sub = goSubStructName(ifaceName)
    g.add(
      "// -------- " & sub & " — sub-instance wrapper of " & ifaceName &
        " --------\n\n"
    )
    g.add("type " & sub & " struct {\n")
    g.add("\tctx C.uint32_t\n")
    g.add("\tmu  sync.Mutex\n")
    g.add("}\n\n")
    g.add("func (w *" & sub & ") Ctx() uint32 { return uint32(w.ctx) }\n")
    g.add("func (w *" & sub & ") Valid() bool { return w.ctx != 0 }\n\n")
    g.add("func (w *" & sub & ") Close() {\n")
    g.add("\tw.mu.Lock()\n\tdefer w.mu.Unlock()\n")
    g.add("\tif w.ctx != 0 {\n")
    g.add("\t\tC." & p & "releaseInstance(w.ctx)\n")
    g.add("\t\tw.ctx = 0\n")
    g.add("\t}\n")
    g.add("}\n\n")
    # internalCborCall (same shape as the Lib method, keyed by w.ctx). The
    # receiver var is named `l` so the shared request-method emitter (which
    # calls `l.internalCborCall`) works unchanged.
    g.add(
      "func (l *" & sub &
        ") internalCborCall(apiName string, args interface{}) ([]byte, error) {\n"
    )
    g.add("\tif l.ctx == 0 { return nil, errors.New(\"sub-instance is released\") }\n")
    g.add("\tvar inBytes []byte\n")
    g.add("\tif args != nil {\n")
    g.add("\t\tvar err error\n")
    g.add("\t\tinBytes, err = cbor.Marshal(args)\n")
    g.add("\t\tif err != nil { return nil, err }\n")
    g.add("\t}\n")
    g.add("\tcName := C.CString(apiName)\n")
    g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
    g.add("\tvar inPtr unsafe.Pointer\n")
    g.add("\tif len(inBytes) > 0 {\n")
    g.add("\t\tinPtr = C." & p & "allocBuffer(C.int32_t(len(inBytes)))\n")
    g.add("\t\tif inPtr == nil { return nil, errors.New(\"allocBuffer failed\") }\n")
    g.add("\t\tC.memcpy(inPtr, unsafe.Pointer(&inBytes[0]), C.size_t(len(inBytes)))\n")
    g.add("\t}\n")
    g.add("\tvar outBuf unsafe.Pointer\n")
    g.add("\tvar outLen C.int32_t\n")
    g.add(
      "\trc := C." & p &
        "call(l.ctx, cName, inPtr, C.int32_t(len(inBytes)), &outBuf, &outLen)\n"
    )
    g.add("\tif rc != 0 {\n")
    g.add("\t\tif outBuf != nil { C." & p & "freeBuffer(outBuf) }\n")
    g.add("\t\treturn nil, errors.New(\"call returned non-zero\")\n")
    g.add("\t}\n")
    g.add("\tif outBuf == nil { return nil, nil }\n")
    g.add("\tout := C.GoBytes(outBuf, C.int(outLen))\n")
    g.add("\tC." & p & "freeBuffer(outBuf)\n")
    g.add("\treturn out, nil\n")
    g.add("}\n\n")
    for e in requestEntries:
      if interfaceOwningRequestType(e.responseTypeName) == ifaceName:
        g.add(emitGoReqMethod(e, sub))
        g.add(emitGoContextMethod(e, sub))
    # Sub-interface one-way signals (routed by l.ctx — this instance). Emit
    # signalCall only when this sub-interface owns at least one signal.
    var ifaceSigs: seq[CborSignalEntry] = @[]
    for s in signalEntries:
      if interfaceOwningSignalType(s.typeName) == ifaceName:
        ifaceSigs.add(s)
    if ifaceSigs.len > 0:
      g.add(emitGoSignalCall(sub))
      for s in ifaceSigs:
        g.add(emitGoSignalMethod(s, sub))
    # Sub-interface event methods (subscribe/unsubscribe keyed by l.ctx).
    for ev in eventEntries:
      if interfaceOwningEventType(ev.typeName) != ifaceName:
        continue
      let exName = snakeToPascal(ev.apiName)
      let payloadType = ev.typeName
      var fieldNames: seq[string] = @[]
      var fieldGoTypes: seq[string] = @[]
      var fieldExNames: seq[string] = @[]
      var fieldsOk = true
      let scalarEvt = isScalarPayload(payloadType)
      if scalarEvt:
        fieldNames.add("value")
        fieldGoTypes.add(primGoHint(resolveUnderlyingType(payloadType)))
        fieldExNames.add("value")
      elif isTypeRegistered(payloadType):
        let entry = lookupTypeEntry(payloadType)
        for f in entry.fields:
          let h = nimTypeToGoCborHint(f.nimType)
          if h.len == 0:
            fieldsOk = false
            break
          fieldNames.add(f.name)
          fieldGoTypes.add(h)
          fieldExNames.add(goExportedField(f.name))
      else:
        fieldsOk = false
      if not fieldsOk:
        g.add(
          "// TODO(go-codegen-cbor): event '" & payloadType &
            "' has fields not yet mappable\n"
        )
        g.add(
          "func (l *" & sub & ") On" & exName & "(cb func(" & payloadType &
            ")) uint64 { _ = cb; return 0 }\n\n"
        )
      else:
        var sig = ""
        for i in 0 ..< fieldNames.len:
          if i > 0:
            sig.add(", ")
          sig.add(fieldNames[i] & " " & fieldGoTypes[i])
        g.add("func (l *" & sub & ") On" & exName & "(cb func(" & sig & ")) uint64 {\n")
        g.add("\tif l.ctx == 0 { return 0 }\n")
        g.add("\twrap := cborEventHandler(func(payload []byte) {\n")
        g.add("\t\tvar p " & payloadType & "\n")
        g.add("\t\tif derr := cbor.Unmarshal(payload, &p); derr != nil { return }\n")
        g.add("\t\tcb(")
        if scalarEvt:
          g.add("p")
        else:
          for i in 0 ..< fieldNames.len:
            if i > 0:
              g.add(", ")
            g.add("p." & fieldExNames[i])
        g.add(")\n")
        g.add("\t})\n")
        g.add("\th := cgo.NewHandle(wrap)\n")
        g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
        g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
        g.add(
          "\thandle := uint64(C.go_cbor_subscribe(l.ctx, cName, unsafe.Pointer(h)))\n"
        )
        g.add("\tif handle == 0 {\n")
        g.add("\t\th.Delete()\n")
        g.add("\t\treturn 0\n")
        g.add("\t}\n")
        g.add("\tregisterCborHandle(l.ctx, h)\n")
        g.add("\treturn handle\n")
        g.add("}\n\n")
      g.add("func (l *" & sub & ") Off" & exName & "(handle uint64) {\n")
      g.add("\tif l.ctx == 0 { return }\n")
      g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
      g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
      g.add("\tC." & p & "unsubscribe(l.ctx, cName, C.uint64_t(handle))\n")
      g.add("}\n\n")

  try:
    writeFile(modDir & "/" & libName & ".go", g)
  except IOError:
    error("Failed to write CBOR Go file: " & getCurrentExceptionMsg())

  # ---------------------- <libName>_callbacks.c ----------------------
  # Bridges the Go //export trampolines to the C library's callback-taking
  # entry points. The subscribe shim is only emitted when events exist (its
  # trampoline is only //export'd then); the async-call shim whenever requests
  # exist. Every library has requests, so this file is always written.
  if requestEntries.len > 0 or eventEntries.len > 0:
    var c = "// Generated by nim-brokers CBOR FFI Go codegen — do not edit.\n"
    c.add("#include <stdint.h>\n")
    c.add("#include <stdlib.h>\n")
    c.add("#include \"" & libName & ".h\"\n")
    c.add("#include \"_cgo_export.h\"\n\n")
    if eventEntries.len > 0:
      c.add(
        "uint64_t go_cbor_subscribe(uint32_t ctx, const char* name, void* user_data) {\n"
      )
      c.add(
        "    return " & p & "subscribe(ctx, name, (" & p &
          "event_cb_t)goCborEventTrampoline, user_data);\n"
      )
      c.add("}\n\n")
    if requestEntries.len > 0:
      c.add(
        "int32_t go_cbor_call_async(uint32_t ctx, const char* name, const void* in_buf, int32_t in_len, uint64_t req_id, uint32_t timeout_ms, void* user_data) {\n"
      )
      c.add(
        "    return " & p & "callAsync(ctx, name, in_buf, in_len, req_id, timeout_ms, (" &
          p & "response_cb_t)goCborResponseTrampoline, user_data);\n"
      )
      c.add("}\n")
    try:
      writeFile(modDir & "/" & libName & "_callbacks.c", c)
    except IOError:
      error("Failed to write CBOR Go callbacks file: " & getCurrentExceptionMsg())

{.push raises: [].}
{.pop.}
