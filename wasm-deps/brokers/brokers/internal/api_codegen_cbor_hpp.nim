## Generated C++ header-only wrapper for the CBOR FFI surface.
##
## The wrapper lives entirely in headers — no separate translation
## unit — so foreign C++ projects only need to link the Nim-built
## shared library and `#include` the generated `<lib>.hpp`.
##
## Phase 4c emits typed C++ structs + JSONCONS_ALL_MEMBER_TRAITS macros
## for each registered request response, request args, and event
## payload type, and per-request methods on the `Lib` class that
## CBOR-encode the args, dispatch through the C gate, and decode the
## response envelope into a `Result<T>`.
##
## The wrapper requires:
##   - C++20 (std::span, std::optional, structured bindings)
##   - jsoncons + jsoncons_ext/cbor headers in the include path
##
## Currently supported field/parameter Nim types: bool, int/int8..int64,
## uint8..uint64, float32/float64, string. seq[T], array[N, T], Option[T],
## and nested objects are deferred to a later phase that exercises the
## full type-mapping matrix (Phase 7).

{.push raises: [].}

import std/[macros, os, strutils]
import ./api_common, ./api_schema
import ./helper/broker_utils # reduced-A: per-interface partitioning

# ---------------------------------------------------------------------------
# Nim → C++ type mapping
# ---------------------------------------------------------------------------

proc primCppType(nimType: string): string {.compileTime.} =
  ## Direct primitive mapping. Empty string for non-primitives.
  case nimType.strip()
  of "bool": "bool"
  of "string": "std::string"
  of "int", "int64": "int64_t"
  of "int8": "int8_t"
  of "int16": "int16_t"
  of "int32": "int32_t"
  of "uint", "uint64": "uint64_t"
  of "uint8", "byte": "uint8_t"
  of "uint16": "uint16_t"
  of "uint32": "uint32_t"
  of "float32": "float"
  of "float", "float64": "double"
  of "char": "char"
  else: ""

proc unwrapBracket(s, head: string): string {.compileTime.} =
  ## "seq[X]" + "seq" -> "X"
  let t = s.strip()
  t[head.len + 1 .. ^2].strip()

proc parseArrayInner(s: string): string {.compileTime.} =
  ## "array[N, T]" -> "T"
  let inner = s.strip()[6 ..^ 2]
  let comma = inner.find(',')
  if comma < 0:
    return ""
  inner[comma + 1 .. ^1].strip()

proc parseTableParams*(s: string): (string, string) {.compileTime.} =
  ## "Table[K, V]" -> ("K", "V"). The key is always a scalar (no nested
  ## commas), so the first top-level comma separates key from value; the
  ## value may itself carry commas (array[N, T], nested Table[..]).
  let inner = s.strip()[6 ..^ 2] # strip "Table[" and "]"
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

proc nimTypeToCppType*(nimType: string): string {.compileTime.} =
  ## Recursive Nim → C++ type mapping. Returns "" for unmappable types
  ## (callers emit a TODO and skip the affected typed surface).
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  let prim = primCppType(t)
  if prim.len > 0:
    return prim
  if lower.startsWith("table[") and lower.endsWith("]"):
    # Table[K, V] -> std::unordered_map<Kcpp, Vcpp>, all scalar key types.
    # Keys ride the wire as CBOR text strings; jsoncons cannot parse a text key
    # into a non-string key, so structs holding such a field get a wire-struct
    # + custom json_type_traits that convert (see generateCborHppFile).
    let (k, v) = parseTableParams(t)
    let kc = nimTypeToCppType(k)
    let vc = nimTypeToCppType(v)
    return
      if kc.len > 0 and vc.len > 0:
        "std::unordered_map<" & kc & ", " & vc & ">"
      else:
        ""
  if lower == "seq[byte]":
    # `Bytes` is a per-library wrapper over `std::vector<uint8_t>` (idiomatic,
    # dependency-free, supports .size()/[]/begin()/end()) that carries a
    # `json_type_traits` specialisation forcing CBOR byte-string (major type 2)
    # on the wire — what the Nim cbor_serialization decoder expects for
    # `seq[byte]`. A bare `std::vector<uint8_t>` would ride as a CBOR array
    # (major type 4) and be rejected on INBOUND params. Because the traits
    # attach to the TYPE (not per field), `std::optional<Bytes>`,
    # `std::vector<Bytes>`, and nested structs compose automatically.
    # The type + traits are emitted once per library (see emitBytesType /
    # emitBytesTraits in generateCborCppHeaderFile).
    return "Bytes"
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = nimTypeToCppType(unwrapBracket(t, "seq"))
    return
      if inner.len > 0:
        "std::vector<" & inner & ">"
      else:
        ""
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToCppType(elem)
    # `std::vector` keeps the trait machinery uniform with seq[T] and
    # matches what jsoncons decodes a CBOR array into. The Nim side
    # range-checks the array length on decode.
    return
      if inner.len > 0:
        "std::vector<" & inner & ">"
      else:
        ""
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToCppType(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "std::optional<" & inner & ">"
      else:
        ""
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return t
    of atkEnum:
      return t
    of atkAlias, atkDistinct:
      # The alias is emitted as `using <name> = <mapped>;`, so reference it BY
      # NAME — a field/param keeps the meaningful type (`ContentTopic timestamp`,
      # `Timestamp timestamp`) instead of being flattened to the primitive —
      # provided the underlying actually maps; else "" so the caller emits a TODO.
      # (The alias *definition* itself passes the resolved underlying, not the
      # name, so `using ContentTopic = std::string;` is unaffected.)
      if nimTypeToCppType(resolveUnderlyingType(t)).len > 0:
        return t
      return ""
  ""

proc isCppMappable*(nimType: string): bool {.compileTime.} =
  nimTypeToCppType(nimType).len > 0

proc cppTableKeyType*(nimType: string): string {.compileTime.} =
  let (k, _) = parseTableParams(nimType.strip())
  nimTypeToCppType(k)

proc cppTableValType*(nimType: string): string {.compileTime.} =
  let (_, v) = parseTableParams(nimType.strip())
  nimTypeToCppType(v)

proc cppTableNeedsKeyConv*(nimType: string): bool {.compileTime.} =
  ## True for a Table[K, V] whose C++ key type is not `std::string`
  ## (int / enum / char / distinct-of-scalar). jsoncons can't parse a text
  ## key into such a type, so the owning struct gets a wire-struct + custom
  ## json_type_traits that convert.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if not (lower.startsWith("table[") and lower.endsWith("]")):
    return false
  let kc = cppTableKeyType(t)
  kc.len > 0 and kc != "std::string"

proc cppWireFieldType*(nimType: string): string {.compileTime.} =
  ## Field type for the string-keyed wire struct: non-string-keyed maps
  ## become `std::unordered_map<std::string, V>`; everything else is itself.
  if cppTableNeedsKeyConv(nimType):
    "std::unordered_map<std::string, " & cppTableValType(nimType) & ">"
  else:
    nimTypeToCppType(nimType)

proc structHasKeyConv*(entry: ApiTypeEntry): bool {.compileTime.} =
  for f in entry.fields:
    if cppTableNeedsKeyConv(f.nimType):
      return true
  false

# ---------------------------------------------------------------------------
# Identifier helpers
# ---------------------------------------------------------------------------

proc snakeToLowerCamel*(s: string): string {.compileTime.} =
  ## "get_status" -> "getStatus", "add_numbers" -> "addNumbers".
  result = ""
  var capitalize = false
  for ch in s:
    if ch == '_':
      capitalize = true
    elif capitalize:
      result.add(toUpperAscii(ch))
      capitalize = false
    else:
      result.add(ch)

# ---------------------------------------------------------------------------
# Event callback parameter mapping
# ---------------------------------------------------------------------------
#
# For event payload fields we deliver UNPACKED positional args to user
# callbacks (mirroring native FFI mode). The parameter type differs from
# the storage type for non-POD fields:
#   string       -> std::string_view  (zero-copy view on decoded std::string)
#   seq[T]       -> std::span<const Tcpp>  (view on decoded std::vector)
#   array[N, T]  -> std::span<const Tcpp>  (CBOR decodes array into vector)
#   nested obj   -> const T&
#   primitives   -> by value
#
# `eventCallbackParamType` returns the C++ parameter type spelling.
# `eventCallbackArgExpr` returns the expression that pulls the arg out
# of the decoded payload struct (named `evt`).

proc eventCallbackParamType*(nimType: string): string {.compileTime.} =
  ## Returns the C++ parameter type for unpacked event callback args.
  ## Empty string => the field's underlying Nim type isn't mappable.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  let prim = primCppType(t)
  if prim.len > 0:
    if t == "string":
      return "std::string_view"
    return prim
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let innerNim = unwrapBracket(t, "seq")
    # seq[string] -> span<const std::string_view> (parity with native FFI;
    # the trampoline materialises a temporary vector<string_view> over
    # the decoded vector<string>).
    if innerNim.strip() == "string":
      return "std::span<const std::string_view>"
    let inner = nimTypeToCppType(innerNim)
    return
      if inner.len > 0:
        "std::span<const " & inner & ">"
      else:
        ""
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToCppType(elem)
    return
      if inner.len > 0:
        "std::span<const " & inner & ">"
      else:
        ""
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToCppType(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "std::optional<" & inner & ">"
      else:
        ""
  if lower.startsWith("table[") and lower.endsWith("]"):
    # Deliver the decoded map by const reference (no view materialisation).
    let m = nimTypeToCppType(t)
    return
      if m.len > 0:
        "const " & m & "&"
      else:
        ""
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return "const " & t & "&"
    of atkEnum:
      return t
    of atkAlias, atkDistinct:
      # Deliver the unpacked callback arg by its alias NAME (`ChannelId channelId`,
      # `Timestamp timestamp`) — `nimTypeToCppType` already yields the emitted
      # alias name, matching the struct field type and the Rust/Go callbacks.
      return nimTypeToCppType(t)
  ""

proc eventCallbackArgExpr*(fieldName, nimType: string): string {.compileTime.} =
  ## Builds the expression that destructures `evt.<fieldName>` into the
  ## callback param shape returned by `eventCallbackParamType`.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if t == "string":
    return "std::string_view(evt." & fieldName & ")"
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let innerNim = unwrapBracket(t, "seq")
    # seq[string]: pass a span over the temporary vector<string_view>
    # built in the invoke preamble (see eventCallbackInvokeSetup).
    if innerNim.strip() == "string":
      return "std::span<const std::string_view>(" & fieldName & "_view)"
    let inner = nimTypeToCppType(innerNim)
    if inner.len > 0:
      return "std::span<const " & inner & ">(evt." & fieldName & ")"
    return "evt." & fieldName
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToCppType(elem)
    if inner.len > 0:
      return "std::span<const " & inner & ">(evt." & fieldName & ")"
    return "evt." & fieldName
  # Primitives, enums, distincts, options, nested objects: pass directly.
  "evt." & fieldName

proc eventCallbackInvokeSetup*(fieldName, nimType: string): string {.compileTime.} =
  ## Returns setup statements emitted inside `invoke()` BEFORE the user
  ## callback is called. Used to materialise non-owning views over the
  ## decoded payload (e.g. seq[string] -> vector<string_view>) so the
  ## span the user receives stays valid for the call duration.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if lower.startsWith("seq[") and lower.endsWith("]") and
      unwrapBracket(t, "seq").strip() == "string":
    let viewVar = fieldName & "_view"
    return
      "      std::vector<std::string_view> " & viewVar & ";\n" & "      " & viewVar &
      ".reserve(evt." & fieldName & ".size());\n" & "      for (const auto& s : evt." &
      fieldName & ") " & viewVar & ".emplace_back(s);\n"
  ""

# ---------------------------------------------------------------------------
# Per-type emission
# ---------------------------------------------------------------------------

proc emitCppStructFields*(h: var string, entry: ApiTypeEntry): bool {.compileTime.} =
  ## Emit the body of a C++ struct mirroring `entry.fields`. Returns true
  ## when every field was successfully mapped. False (with a TODO comment
  ## emitted) means the wrapper should skip emitting this type's typed
  ## method to avoid handing out a half-mapped surface.
  result = true
  for f in entry.fields:
    let cppType = nimTypeToCppType(f.nimType)
    if cppType.len == 0:
      h.add("  // TODO: Nim type '" & f.nimType & "' not yet mappable to C++\n")
      result = false
    else:
      h.add("  " & cppType & " " & f.name & "{};\n")

proc emitMemberTraitsMacro*(
    h: var string, qualifiedName: string, typeName: string, fieldNames: seq[string]
) {.compileTime.} =
  ## Emit a JSONCONS member-traits macro for `<qualifiedName>`.
  ##
  ## When the registered struct contains any `Option[T]` field, switch
  ## from the `_ALL_` flavour (every member required) to the `_N_`
  ## flavour with `N = required.len`, listing required fields first
  ## then optional ones. Without this split, decoding a payload where
  ## an `Option` field is `none` (no key on the wire) fails with
  ## `Key 'X' not found`.
  ##
  ## Per jsoncons docs, these macros generate partial specialisations
  ## of `jsoncons::json_type_traits` and must be invoked at namespace
  ## scope enclosing `jsoncons` — i.e. global scope, type fully
  ## qualified. Empty structs are skipped; jsoncons handles those
  ## implicitly when nested via Option fields.
  if fieldNames.len == 0:
    return

  var required: seq[string] = @[]
  var optional: seq[string] = @[]
  if isTypeRegistered(typeName):
    let entry = lookupTypeEntry(typeName)
    for n in fieldNames:
      var isOption = false
      for f in entry.fields:
        if f.name == n:
          if f.nimType.toLowerAscii().startsWith("option["):
            isOption = true
          break
      if isOption:
        optional.add(n)
      else:
        required.add(n)
  else:
    required = fieldNames

  if optional.len == 0:
    h.add("JSONCONS_ALL_MEMBER_TRAITS(" & qualifiedName)
    for n in required:
      h.add(", " & n)
    h.add(")\n")
  else:
    h.add("JSONCONS_N_MEMBER_TRAITS(" & qualifiedName & ", " & $required.len)
    for n in required:
      h.add(", " & n)
    for n in optional:
      h.add(", " & n)
    h.add(")\n")

proc emitEnvelopeTraits*(h: var string, qualifiedName: string) {.compileTime.} =
  ## Emit the JSONCONS macro for `<libname>::<Type>Envelope`. Both fields
  ## are optional on the wire (`omitOptionalFields = true` in the
  ## BrokerCbor flavor), so the required-count is 0.
  h.add("JSONCONS_N_MEMBER_TRAITS(" & qualifiedName & ", 0, ok, err)\n")

proc emitCppMapStructTraits*(
    h: var string, libName, name: string, entry: ApiTypeEntry
) {.compileTime.} =
  ## Custom `json_type_traits<Json, <name>>` for a struct holding non-string-
  ## keyed maps. Delegates all field (de)serialisation to the auto-generated
  ## `<name>__wire` traits and converts only the map keys: text <-> typed
  ## (char via the first byte; int / enum / distinct via std::stoll / to_string).
  let q = libName & "::" & name
  let qw = libName & "::" & name & "__wire"
  h.add("namespace jsoncons {\n")
  h.add("template <typename Json>\n")
  h.add("struct json_type_traits<Json, " & q & "> {\n")
  h.add("  using allocator_type = typename Json::allocator_type;\n")
  h.add("  static bool is(const Json& j) noexcept { return j.is_object(); }\n")
  h.add("  static " & q & " as(const Json& j) {\n")
  h.add("    auto w = j.template as<" & qw & ">();\n")
  h.add("    " & q & " v;\n")
  for f in entry.fields:
    if nimTypeToCppType(f.nimType).len == 0:
      continue
    if cppTableNeedsKeyConv(f.nimType):
      let kt = cppTableKeyType(f.nimType)
      # Registered key types (enum, and now alias/distinct like `JobId`) live in
      # the lib namespace; qualify them for use here inside `namespace jsoncons`.
      # Primitive keys (int*/char → int32_t/char, not registered) stay bare.
      let ktQ =
        if isTypeRegistered(kt):
          libName & "::" & kt
        else:
          kt
      if kt == "char":
        h.add(
          "    for (const auto& kv : w." & f.name & ") v." & f.name &
            "[kv.first.empty() ? char(0) : kv.first[0]] = kv.second;\n"
        )
      else:
        h.add(
          "    for (const auto& kv : w." & f.name & ") v." & f.name & "[static_cast<" &
            ktQ & ">(std::stoll(kv.first))] = kv.second;\n"
        )
    else:
      h.add("    v." & f.name & " = w." & f.name & ";\n")
  h.add("    return v;\n  }\n")
  h.add(
    "  static Json to_json(const " & q &
      "& v, const allocator_type& alloc = allocator_type()) {\n"
  )
  h.add("    " & qw & " w;\n")
  for f in entry.fields:
    if nimTypeToCppType(f.nimType).len == 0:
      continue
    if cppTableNeedsKeyConv(f.nimType):
      let kt = cppTableKeyType(f.nimType)
      if kt == "char":
        h.add(
          "    for (const auto& kv : v." & f.name & ") w." & f.name &
            "[std::string(1, kv.first)] = kv.second;\n"
        )
      else:
        h.add(
          "    for (const auto& kv : v." & f.name & ") w." & f.name &
            "[std::to_string(static_cast<long long>(kv.first))] = kv.second;\n"
        )
    else:
      h.add("    w." & f.name & " = v." & f.name & ";\n")
  h.add("    return json_type_traits<Json, " & qw & ">::to_json(w, alloc);\n  }\n")
  h.add("};\n")
  h.add("} // namespace jsoncons\n\n")

# ---------------------------------------------------------------------------
# Header file emission
# ---------------------------------------------------------------------------

{.pop.}

proc cppSubClassName(iface: string): string {.compileTime.} =
  ## Wrapper class name for a sub-interface: strip a leading `I` before an
  ## uppercase letter (IWidget -> Widget), else use the name as-is.
  if iface.len > 1 and iface[0] == 'I' and iface[1] in {'A' .. 'Z'}:
    iface[1 ..^ 1]
  else:
    iface

proc generateCborCppHeaderFile*(
    outDir: string,
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
    mainClass: string = "",
    asyncTimeoutMs: int = 30000,
    asyncQueueDepth: int = 64,
    signalEntries: seq[CborSignalEntry] = @[],
) {.compileTime, raises: [].} =
  ## Writes the C++ wrapper header (.hpp) for a CBOR-mode library.
  ensureGeneratedOutputDir(outDir)
  let upperLib = libName.toUpperAscii().replace("-", "_")
  let defaultTimeoutMacro = upperLib & "_DEFAULT_ASYNC_TIMEOUT_MS"
  let queueDepthMacro = upperLib & "_ASYNC_QUEUE_DEPTH"

  # reduced-A: an entry belongs to the main class when no mainClass is
  # designated (legacy single class), or it is flat, or its owning interface is
  # the main class. Sub-interface names are derived from the entries directly
  # (interfaceOwningRequestType), not apiInterfaces() — the compile-time VM
  # aliases a by-value seq return to an empty copy.
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
  var anyInstanceReturn = false
  if mainClass.len > 0:
    for e in requestEntries:
      if e.returnsInterface.len > 0:
        anyInstanceReturn = true
      let o = interfaceOwningRequestType(e.responseTypeName)
      if o.len > 0 and o != mainClass and o notin subInterfaceNames:
        subInterfaceNames.add(o)

  let guardName = libName.toUpperAscii().replace("-", "_") & "_HPP"
  let headerPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".hpp"
    else:
      libName & ".hpp"
  let p = libName & "_"

  # Derive C++ class name from libName the same way the native codegen
  # does: snake_case / kebab-case → PascalCase. "mylib" -> "Mylib",
  # "typemappingtestlib_cbor" -> "TypemappingtestlibCbor". Keeps the
  # public C++ surface identical between native and CBOR builds so the
  # same client `main.cpp` can compile against either.
  var className = ""
  var capitalize = true
  for ch in libName:
    if ch == '_' or ch == '-':
      capitalize = true
    elif capitalize:
      className.add(chr(ord(ch) - 32 * ord(ch in {'a' .. 'z'})))
      capitalize = false
    else:
      className.add(ch)

  # Note: emittablePayloads is computed below from the actual struct
  # emission, not from the response / event lookup, so we cover types
  # transitively referenced from object fields (seq[Tag], etc.).

  var h =
    "// Generated by nim-brokers CBOR FFI codegen — do not edit.\n" & "//\n" &
    "// Header-only C++ wrapper around the C ABI declared in `" & libName & ".h`.\n" &
    "// Requires C++20 and jsoncons + jsoncons_ext/cbor in the include path.\n" &
    "#ifndef " & guardName & "\n" & "#define " & guardName & "\n\n" & "#include \"" &
    libName & ".h\"\n\n" & "#include <jsoncons/json.hpp>\n" &
    "#include <jsoncons_ext/cbor/cbor.hpp>\n\n" & "#include <atomic>\n" &
    "#include <chrono>\n" & "#include <cstdint>\n" & "#include <cstring>\n" &
    "#include <functional>\n" & "#include <future>\n" & "#include <memory>\n" &
    "#include <optional>\n" & "#include <semaphore>\n" & "#include <span>\n" &
    "#include <string>\n" & "#include <system_error>\n" & "#include <unordered_map>\n" &
    "#include <utility>\n" & "#include <vector>\n\n" & "namespace " & libName & " {\n\n"

  # Result<T>
  h.add("template <typename T>\n")
  h.add("class Result {\n")
  h.add("    std::optional<T> value_;\n")
  h.add("    std::string error_;\n")
  h.add("public:\n")
  h.add("    static Result<T> ok(T value) {\n")
  h.add("        Result<T> r;\n")
  h.add("        r.value_ = std::move(value);\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    static Result<T> err(std::string message) {\n")
  h.add("        Result<T> r;\n")
  h.add("        r.error_ = std::move(message);\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    bool isOk() const { return value_.has_value(); }\n")
  h.add("    bool isErr() const { return !value_.has_value(); }\n")
  h.add("    explicit operator bool() const { return isOk(); }\n")
  h.add("    const T& value() const { return *value_; }\n")
  h.add("    T& value() { return *value_; }\n")
  h.add("    const T& operator*() const { return *value_; }\n")
  h.add("    const T* operator->() const { return &*value_; }\n")
  h.add("    T&& take() { return std::move(*value_); }\n")
  h.add("    const std::string& error() const { return error_; }\n")
  h.add("};\n\n")
  h.add("template <>\n")
  h.add("class Result<void> {\n")
  h.add("    bool ok_ = true;\n")
  h.add("    std::string error_;\n")
  h.add("public:\n")
  h.add("    static Result<void> ok() {\n")
  h.add("        Result<void> r;\n")
  h.add("        r.ok_ = true;\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    static Result<void> err(std::string message) {\n")
  h.add("        Result<void> r;\n")
  h.add("        r.ok_ = false;\n")
  h.add("        r.error_ = std::move(message);\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    Result() = default;\n")
  h.add("    bool isOk() const { return ok_; }\n")
  h.add("    bool isErr() const { return !ok_; }\n")
  h.add("    explicit operator bool() const { return isOk(); }\n")
  h.add("    const std::string& error() const { return error_; }\n")
  h.add("};\n\n")

  # ---- Bytes ----
  # Idiomatic byte vector for `seq[byte]`. Derives std::vector<uint8_t> so the
  # public surface is dependency-free (.size()/[]/begin()/end()/push_back),
  # while a json_type_traits specialisation (emitted after this namespace)
  # forces a CBOR byte string (major type 2) on the wire. Setting
  # is_json_type_traits_declared<Bytes> there disables jsoncons' built-in
  # byte-container paths (which would encode std::vector<uint8_t> as a CBOR
  # array), so the custom traits drive both encode and decode and compose
  # through std::optional<Bytes>, std::vector<Bytes>, and nested structs.
  h.add("struct Bytes : std::vector<uint8_t> {\n")
  h.add("  using std::vector<uint8_t>::vector;\n")
  h.add("  Bytes() = default;\n")
  h.add(
    "  explicit Bytes(std::vector<uint8_t> v) : std::vector<uint8_t>(std::move(v)) {}\n"
  )
  h.add("};\n\n")

  # ---- All registered enums + distinct/alias aliases + structs ----
  # We walk gApiTypeRegistry directly so types referenced from fields
  # (e.g. `seq[Tag]` inside an object) get emitted, not just the
  # immediate request-response or event-payload types.
  var enumNames: seq[string] = @[]
  var aliasNames: seq[string] = @[]
  var objectNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.name.endsWith("CborArgs"):
      continue # synthetic args structs are emitted per-request below
    case entry.kind
    of atkEnum:
      enumNames.add(entry.name)
    of atkDistinct, atkAlias:
      aliasNames.add(entry.name)
    of atkObject:
      objectNames.add(entry.name)

  # Enum class declarations — the underlying type is fixed at int32_t so
  # the wire encoding (CBOR Unsigned, ordinal value) round-trips with
  # the BrokerCbor flavor's `enumRep = EnumAsNumber`.
  if enumNames.len > 0:
    h.add("// ---- Enums ----\n\n")
  for name in enumNames:
    let entry = lookupTypeEntry(name)
    h.add("enum class " & name & " : int32_t {\n")
    if entry.enumValues.len == 0:
      h.add("};\n\n")
      continue
    for v in entry.enumValues:
      h.add("  " & v.name & " = " & $v.ordinal & ",\n")
    h.add("};\n\n")

  # Object forward declarations FIRST, so a `using X = SomeObject` alias (a
  # proc-sugar broker returning an object) and cross-references like
  # `std::vector<Tag>` compile regardless of registry order.
  if objectNames.len > 0:
    h.add("// ---- Object payload structs ----\n\n")
    for name in objectNames:
      h.add("struct " & name & ";\n")
    h.add("\n")

  # Distinct / alias — `using` aliases of the underlying mapped type. Uses the
  # full mapper (not just primCppType) so a container payload like
  # `proc connectedPeers(): Result[seq[string]]` emits
  # `using ConnectedPeers = std::vector<std::string>;`, and an object payload
  # `proc getRow(): Result[RowData]` emits `using GetRow = RowData;` (RowData is
  # forward-declared just above).
  # Response-payload type names — a synthetic proc-sugar alias (`Send`,
  # `StartDiscv5`, `GetRow`) is unwrapped to its real payload everywhere it is
  # used, so its `using <Verb> = ...;` alias is dead — skip it. An anonymous
  # container alias (`ConnectedPeers = seq[string]`) stays (it is the only handle
  # for that type); a field-used alias (`ContentTopic`) is never a response name.
  var responseNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len > 0 and e.responseTypeName notin responseNames:
      responseNames.add(e.responseTypeName)
  if aliasNames.len > 0:
    h.add("// ---- Distinct / alias types ----\n\n")
  for name in aliasNames:
    if name in responseNames and effectiveResponsePayload(name) != name:
      continue
    let underlying = resolveUnderlyingType(name)
    let cpp = nimTypeToCppType(underlying)
    if cpp.len == 0:
      h.add(
        "// TODO: alias '" & name & "' resolves to '" & underlying &
          "' which has no C++ mapping\n\n"
      )
      continue
    h.add("using " & name & " = " & cpp & ";\n")
  if aliasNames.len > 0:
    h.add("\n")

  # Captured (typeName, [fieldName...]) for global-scope JSONCONS macros.
  var payloadFields: seq[(string, seq[string])] = @[]
  for name in objectNames:
    let entry = lookupTypeEntry(name)
    h.add("struct " & name & " {\n")
    var allMapped = true
    for f in entry.fields:
      let cppType = nimTypeToCppType(f.nimType)
      if cppType.len == 0:
        h.add("  // TODO: Nim type '" & f.nimType & "' not yet mappable\n")
        allMapped = false
      else:
        h.add("  " & cppType & " " & f.name & "{};\n")
    h.add("};\n")
    # A string-keyed mirror struct for structs holding non-string-keyed maps.
    # jsoncons auto-(de)serialises this; the public struct's custom traits
    # convert keys to/from it (see the json_type_traits emission below).
    if allMapped and structHasKeyConv(entry):
      h.add("struct " & name & "__wire {\n")
      for f in entry.fields:
        h.add("  " & cppWireFieldType(f.nimType) & " " & f.name & "{};\n")
      h.add("};\n")
    if allMapped:
      var fieldNames: seq[string] = @[]
      for f in entry.fields:
        fieldNames.add(f.name)
      payloadFields.add((name, fieldNames))
    h.add("\n")

  # Names of object types we successfully emitted with full field
  # coverage — used to gate request/event method emission below.
  var emittablePayloads: seq[string] = @[]
  for (name, _) in payloadFields:
    emittablePayloads.add(name)

  # A "scalar payload" is a primitive (non-object) broker type — `type X =
  # int32` — registered as a distinct alias of its underlying primitive.
  # The CBOR wire value is a bare scalar; the C++ surface uses the `using X
  # = <prim>` alias directly (no struct). Such a type is an emittable
  # request response / event payload even though it has no object fields.
  # Uses the full mapper (not just primCppType) so a non-object payload that
  # resolves to a container (`seq[string]` -> std::vector<std::string>) is
  # emittable too, not only bare primitives.
  proc isScalarPayload(name: string): bool {.compileTime.} =
    name.len > 0 and isTypeRegistered(name) and
      lookupTypeEntry(name).kind in {atkAlias, atkDistinct} and
      nimTypeToCppType(resolveUnderlyingType(name)).len > 0

  # A "void payload" is a zero-field broker type — `type X = void` (lowered
  # to an empty object). It has no value; the request envelope carries only
  # the ok/err signal and the event callback no payload. jsoncons cannot
  # (de)serialise a bare empty struct, so the payload slot uses the generic
  # `jsoncons::json` (which round-trips the empty `{}` map) and the request
  # method surfaces as `Result<void>`.
  proc isVoidPayload(name: string): bool {.compileTime.} =
    name.len > 0 and isTypeRegistered(name) and lookupTypeEntry(name).kind == atkObject and
      lookupTypeEntry(name).fields.len == 0

  proc isEmittablePayload(name: string): bool {.compileTime.} =
    name in emittablePayloads or isScalarPayload(name)

  # The C++ type used in the request/event payload slot: `void` surfaces a
  # `Result<void>`; a bare-primitive proc-sugar payload surfaces the simple type
  # directly (`Result<bool>`, not `Result<StartDiscv5>`); other scalar/object
  # payloads use their own (named) type.
  proc payloadCppType(name: string): string {.compileTime.} =
    if isVoidPayload(name):
      return "void"
    let eff = effectiveResponsePayload(name)
    if isNimPrimitive(eff):
      return primCppType(eff)
    eff

  # Effective callback/struct fields for a payload type: an object's real
  # fields, or a single synthetic `value` field for a scalar payload.
  proc effectiveFields(name: string): seq[ApiFieldDef] {.compileTime.} =
    if isScalarPayload(name):
      return @[ApiFieldDef(name: "value", nimType: resolveUnderlyingType(name))]
    lookupTypeEntry(name).fields

  # ---- Compute envelope / args metadata (no emission yet) ----
  var envelopeNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if not isEmittablePayload(e.responseTypeName):
      continue
    let envName = e.responseTypeName & "Envelope"
    if envName notin envelopeNames:
      envelopeNames.add(envName)

  var argsStructByApi: seq[(string, string)] = @[] # (apiName, argsStructName)
  var argsMethodSupported: seq[(string, bool)] = @[] # (apiName, allMapped)
  var argsFields: seq[(string, seq[string])] = @[] # (typeName, [fieldName])
  for e in requestEntries:
    if e.argFields.len == 0:
      argsMethodSupported.add((e.apiName, true))
      continue
    var allMapped = true
    for (n, t) in e.argFields:
      if not isCppMappable(t):
        allMapped = false
        break
    argsMethodSupported.add((e.apiName, allMapped))
    if not allMapped:
      continue
    let camelBase = snakeToLowerCamel(e.apiName)
    var argsName = camelBase & "Args"
    if argsName.len > 0:
      argsName[0] = toUpperAscii(argsName[0])
    argsStructByApi.add((e.apiName, argsName))
    var fieldNames: seq[string] = @[]
    for (n, t) in e.argFields:
      fieldNames.add(n)
    argsFields.add((argsName, fieldNames))

  # Lookup helpers.
  proc argsStructName(apiName: string): string {.compileTime.} =
    for (n, s) in argsStructByApi:
      if n == apiName:
        return s
    ""

  proc isMethodSupported(apiName: string): bool {.compileTime.} =
    for (n, ok) in argsMethodSupported:
      if n == apiName:
        return ok
    false

  # Pre-compute event eligibility: an event is "emittable" iff its payload
  # struct was fully mapped AND every field has an unpacked-callback param
  # mapping (string -> string_view, seq -> span, etc.).
  var emittableEvents: seq[CborEventEntry] = @[]
  for ev in eventEntries:
    if ev.typeName.len == 0 or not isEmittablePayload(ev.typeName):
      continue
    var allOk = true
    for f in effectiveFields(ev.typeName):
      if eventCallbackParamType(f.nimType).len == 0:
        allOk = false
        break
    if allOk:
      emittableEvents.add(ev)

  # reduced-A: events owned by the main interface (the only ones the main Lib
  # class carries dispatchers/methods for). Traits/forward-decls stay full set.
  var mainEvents: seq[CborEventEntry] = @[]
  for ev in emittableEvents:
    if ownsEvtMain(ev):
      mainEvents.add(ev)

  # Emittable events owned by a given sub-interface, and whether it has any.
  # An event-bearing sub-wrapper carries EventDispatchers (which hold
  # `owner_ = this`), so it must be NON-MOVABLE and is therefore created on the
  # heap and returned as `Result<std::unique_ptr<Sub>>`. An event-free sub
  # (e.g. a request-only IWidget) stays movable and is returned by value.
  proc subEventsOf(ifaceName: string): seq[CborEventEntry] {.compileTime.} =
    for ev in emittableEvents:
      if interfaceOwningEventType(ev.typeName) == ifaceName:
        result.add(ev)

  proc subHasEvents(ifaceName: string): bool {.compileTime.} =
    subEventsOf(ifaceName).len > 0

  # reduced-A: forward-declare each sub-interface wrapper class so the main
  # class can name `Result<Sub>` as a create-instance method return type (a
  # non-defining declaration does not instantiate Result<Sub>, so a forward
  # declaration suffices; the full Sub class is emitted after detail::).
  for ifaceName in subInterfaceNames:
    h.add("class " & cppSubClassName(ifaceName) & ";\n")
  if subInterfaceNames.len > 0:
    h.add("\n")
  # Shared envelope for create-instance responses (wire ok = uint32 ctx).
  if anyInstanceReturn:
    h.add("struct __InstanceCtxEnvelope {\n")
    h.add("  std::optional<uint64_t> ok;\n")
    h.add("  std::optional<std::string> err;\n")
    h.add("};\n\n")

  # ==================================================================
  # Section 0.5: detail:: forward declarations (so Lib can name them)
  # ==================================================================
  h.add("namespace detail {\n")
  h.add("template <typename Owner, typename Traits>\n")
  h.add("class EventDispatcher;\n\n")
  for ev in emittableEvents:
    h.add("struct " & ev.typeName & "EventTraits;\n")
  h.add("} // namespace detail\n\n")

  # ==================================================================
  # Section 1: Lib class — declarations only (no detail:: dependencies)
  # ==================================================================
  h.add("class " & className & " {\n")
  h.add(" public:\n")
  h.add("  " & className & "();\n")
  h.add("  ~" & className & "();\n")
  h.add("  " & className & "(const " & className & "&) = delete;\n")
  h.add("  " & className & "& operator=(const " & className & "&) = delete;\n")
  h.add("  " & className & "(" & className & "&&) = delete;\n")
  h.add("  " & className & "& operator=(" & className & "&&) = delete;\n\n")
  h.add("  static std::string_view version() noexcept;\n\n")
  h.add(
    "  // Max concurrent in-flight <method>Async requests (full => returns the\n" &
      "  // EAGAIN code below). Size a bounded send window to this value.\n"
  )
  h.add("  static constexpr uint32_t asyncQueueDepth = " & queueDepthMacro & ";\n")
  h.add(
    "  // <method>Async returns 0 when queued (callback fires once later) or a\n" &
      "  // negative code when NOT queued (callback does NOT fire):\n"
  )
  h.add(
    "  static constexpr int32_t asyncAgain = " & $ApiStatusAgain &
      ";     // EAGAIN — retry/slow down\n"
  )
  h.add("  static constexpr int32_t asyncBadContext = -5;\n")
  h.add("  static constexpr int32_t asyncNoCallback = -7;\n")
  h.add("  static constexpr int32_t asyncEncodeFailed = -1;\n\n")
  h.add("  Result<void> createContext();\n")
  h.add("  bool validContext() const noexcept;\n")
  h.add("  explicit operator bool() const noexcept;\n")
  h.add("  void shutdown() noexcept;\n")
  h.add("  uint32_t ctx() const noexcept;\n\n")

  # Per-request method declarations (main interface only).
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if not ownsReqMain(e):
      continue
    let methodName = snakeToLowerCamel(e.apiName)
    var sigParams = ""
    if e.argFields.len > 0:
      var first = true
      for (n, t) in e.argFields:
        if not first:
          sigParams.add(", ")
        sigParams.add(nimTypeToCppType(t) & " " & n)
        first = false
    if e.returnsInterface.len > 0:
      # reduced-A: create-instance method returns the typed sub-wrapper —
      # by-value if event-free, or unique_ptr<Sub> if the sub carries events
      # (non-movable, heap-stable for its EventDispatchers).
      let subN = cppSubClassName(e.returnsInterface)
      let retT =
        if subHasEvents(e.returnsInterface):
          "Result<std::unique_ptr<" & subN & ">>"
        else:
          "Result<" & subN & ">"
      h.add("  " & retT & " " & methodName & "(" & sigParams & ");\n")
      continue
    if not isEmittablePayload(e.responseTypeName):
      h.add(
        "  // TODO: '" & e.apiName & "' return type '" & e.responseTypeName &
          "' is not yet emitted as a typed C++ struct.\n"
      )
      continue
    if not isMethodSupported(e.apiName):
      h.add(
        "  // TODO: '" & e.apiName &
          "' has parameters whose Nim types aren't yet mappable to C++.\n"
      )
      continue
    h.add(
      "  Result<" & payloadCppType(e.responseTypeName) & "> " & methodName & "(" &
        sigParams & ");\n"
    )
    # Fire-and-forget async sibling: same args, plus a completion callback and
    # a std::chrono timeout (<= 0ms means infinite; default = library policy).
    # Delivered on the library's event delivery thread. reqId is internal.
    # (Instance-returning create methods are sync-only here.)
    let asyncTail =
      ", std::chrono::milliseconds timeout = std::chrono::milliseconds(" &
      defaultTimeoutMacro & ")"
    let asyncSig =
      if sigParams.len > 0:
        sigParams & ", std::function<void(Result<" & payloadCppType(e.responseTypeName) &
          ">)> cb" & asyncTail
      else:
        "std::function<void(Result<" & payloadCppType(e.responseTypeName) & ">)> cb" &
          asyncTail
    h.add("  int32_t " & methodName & "Async(" & asyncSig & ");\n")
    # Future-returning convenience (built on <method>Async via std::promise —
    # no thread parked per call, unlike wrapping the sync call in std::async).
    # Backpressure-aware: blocks briefly on the window semaphore when full, so
    # this surface never returns EAGAIN.
    let futureTail =
      "std::chrono::milliseconds timeout = std::chrono::milliseconds(" &
      defaultTimeoutMacro & ")"
    let futureSig =
      if sigParams.len > 0:
        sigParams & ", " & futureTail
      else:
        futureTail
    h.add(
      "  std::future<Result<" & payloadCppType(e.responseTypeName) & ">> " & methodName &
        "Future(" & futureSig & ");\n"
    )
  h.add("\n")

  # Per-signal method declarations (one-way; slot-free `_call`). Returns
  # `Result<void>`: ok() = accepted (a handler exists + the queue had room),
  # never "handled". No async sibling — signals are one-way, so a completion
  # callback would carry nothing not already known synchronously.
  proc isObjectSignal(typeName: string): bool {.compileTime.} =
    (not isVoidPayload(typeName)) and isTypeRegistered(typeName) and
      lookupTypeEntry(typeName).kind == atkObject

  proc signalSigParams(typeName: string): tuple[params: string, mappable: bool] =
    result.mappable = true
    if isVoidPayload(typeName):
      return
    var first = true
    for f in effectiveFields(typeName):
      if not isCppMappable(f.nimType):
        result.mappable = false
        return
      if not first:
        result.params.add(", ")
      result.params.add(nimTypeToCppType(f.nimType) & " " & f.name)
      first = false

  # Signal method DECLARATION (class-independent) — shared by the main class and
  # each sub-interface class (a sub-interface signal is emitted on its sub class).
  proc emitSignalDecl(s: CborSignalEntry): string {.compileTime.} =
    let methodName = snakeToLowerCamel(s.apiName)
    if not (
      isVoidPayload(s.typeName) or isObjectSignal(s.typeName) or
      isScalarPayload(s.typeName)
    ):
      return
        "  // TODO: signal '" & s.apiName & "' payload '" & s.typeName &
        "' is not yet emitted as a typed C++ signal method.\n"
    let sp = signalSigParams(s.typeName)
    if not sp.mappable:
      return
        "  // TODO: signal '" & s.apiName &
        "' has fields whose Nim types aren't yet mappable to C++.\n"
    "  Result<void> " & methodName & "(" & sp.params & ");\n"

  # Signal method DEFINITION for class `clsName` (main or a sub class). Both use
  # a `ctx_` member + `detail::rawCallOwned(ctx_, …)`, so the body is identical
  # apart from the `clsName::` qualifier — for a sub class `ctx_` is the
  # sub-instance ctx, so the signal routes to that instance's handler.
  proc emitSignalImpl(s: CborSignalEntry, clsName: string): string {.compileTime.} =
    if not (
      isVoidPayload(s.typeName) or isObjectSignal(s.typeName) or
      isScalarPayload(s.typeName)
    ):
      return ""
    let sp = signalSigParams(s.typeName)
    if not sp.mappable:
      return ""
    let methodName = snakeToLowerCamel(s.apiName)
    result.add(
      "inline Result<void> " & clsName & "::" & methodName & "(" & sp.params & ") {\n"
    )
    if isVoidPayload(s.typeName):
      result.add("  std::string lastError;\n")
      result.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError, \"" & s.apiName &
          "\", nullptr, 0);\n"
      )
    else:
      if isObjectSignal(s.typeName):
        result.add("  " & s.typeName & " __p;\n")
        for f in effectiveFields(s.typeName):
          result.add("  __p." & f.name & " = " & f.name & ";\n")
      else:
        result.add("  const auto& __p = value;\n")
      result.add("  std::size_t cborLen = 0;\n")
      result.add("  try { cborLen = detail::cborEncodedSize(__p); }\n")
      result.add(
        "  catch (const std::exception& ex) { return Result<void>::err(std::string(\"size pass failed: \") + ex.what()); }\n"
      )
      result.add(
        "  void* inBuf = (cborLen > 0) ? " & p &
          "allocBuffer(static_cast<int32_t>(cborLen)) : nullptr;\n"
      )
      result.add(
        "  if (cborLen > 0 && !inBuf) return Result<void>::err(\"allocBuffer failed\");\n"
      )
      result.add("  try {\n")
      result.add(
        "    if (cborLen > 0) detail::cborEncodeInto(__p, static_cast<std::uint8_t*>(inBuf), cborLen);\n"
      )
      result.add("  } catch (const std::exception& ex) {\n")
      result.add("    if (inBuf) { " & p & "freeBuffer(inBuf); }\n")
      result.add(
        "    return Result<void>::err(std::string(\"encode pass failed: \") + ex.what());\n"
      )
      result.add("  }\n")
      result.add("  std::string lastError;\n")
      result.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError, \"" & s.apiName &
          "\", inBuf, cborLen);\n"
      )
    result.add("  if (status == 0) return Result<void>::ok();\n")
    result.add(
      "  if (status == " & $ApiStatusAgain &
        ") return Result<void>::err(\"EAGAIN: signal queue full\");\n"
    )
    result.add(
      "  if (status == " & $ApiStatusProviderErr &
        ") return Result<void>::err(\"no signal handler installed\");\n"
    )
    result.add(
      "  return Result<void>::err(lastError.empty() ? (std::string(\"signal failed: rc=\") + std::to_string(status)) : lastError);\n"
    )
    result.add("}\n\n")

  var mainSigCount = 0
  for s in signalEntries:
    if not ownsSigMain(s):
      continue
    inc mainSigCount
    h.add(emitSignalDecl(s))
  if mainSigCount > 0:
    h.add("\n")

  # Per-event Callback aliases + on/off declarations. The public alias is
  # emitted as a fully-spelled `std::function<...>` (mirrors native FFI)
  # so that Lib's public surface does NOT depend on the detail::Traits
  # struct being complete at this point — only forward-declared. The
  # EventDispatcher's internal `Callback` typedef (resolved from Traits
  # later) produces the same std::function<> instantiation, so the types
  # are interchangeable at call sites.
  for ev in eventEntries:
    if not ownsEvtMain(ev):
      continue # sub-interface events are not in scope for this slice
    if ev notin emittableEvents:
      h.add(
        "  // TODO: event '" & ev.apiName & "' payload type '" & ev.typeName &
          "' is not yet emitted as a typed C++ struct.\n"
      )
      continue
    let camelBase = snakeToLowerCamel(ev.apiName)
    var pascal = camelBase
    if pascal.len > 0:
      pascal[0] = toUpperAscii(pascal[0])
    let callbackAlias = ev.typeName & "Callback"
    let onName = "on" & pascal
    let offName = "off" & pascal
    h.add("  using " & callbackAlias & " = std::function<void(" & className & "&")
    for f in effectiveFields(ev.typeName):
      h.add(", " & eventCallbackParamType(f.nimType) & " " & f.name)
    h.add(")>;\n")
    h.add("  uint64_t " & onName & "(" & callbackAlias & " fn) noexcept;\n")
    h.add("  void " & offName & "(uint64_t handle = 0) noexcept;\n\n")

  # Discovery declarations.
  h.add("  std::string listApis();\n")
  h.add("  std::string getSchema();\n\n")

  # Private section: dispatcher members + ctx.
  # `lastError` is intentionally a per-call local in each generated method —
  # NOT a shared instance member. Sharing it across calls was a data race
  # (concurrent `addRequest`s on one `Lib` instance both write the same
  # `std::string`, leading to a double-free on the SSO/heap buffer —
  # caught by ASAN under stress_shutdown).
  h.add(" private:\n")
  h.add("  uint32_t ctx_ = 0;\n")
  h.add("  // Internal reqId for the ABI (logging/correlation is via the boxed\n")
  h.add("  // callback, not reqId — so it is not part of the typed surface).\n")
  h.add("  std::atomic<uint64_t> asyncReqId_{0};\n")
  h.add("  // <method>Future backpressure: acquire before issue, release in the\n")
  h.add("  // completion callback. Initialised to asyncQueueDepth - 1 because the\n")
  h.add("  // library releases its own depth slot only AFTER the callback returns\n")
  h.add("  // (single delivery thread => at most one such in-flight release), so\n")
  h.add("  // the margin of one makes a post-release reissue race-free.\n")
  h.add(
    "  std::counting_semaphore<> asyncWindow_{static_cast<std::ptrdiff_t>(\n" &
      "      asyncQueueDepth > 1 ? asyncQueueDepth - 1 : 1)};\n"
  )
  for ev in mainEvents:
    let dispatcherType = ev.typeName & "Dispatcher"
    let dispatcherMember = ev.apiName & "Dispatcher_"
    h.add(
      "  using " & dispatcherType & " = detail::EventDispatcher<" & className &
        ", detail::" & ev.typeName & "EventTraits>;\n"
    )
    h.add("  std::unique_ptr<" & dispatcherType & "> " & dispatcherMember & ";\n")
  h.add("};\n\n")

  # ==================================================================
  # Sub-interface request method helpers (compile-time procs).
  # emitSubReqDecl  → in-class signature (declaration only)
  # emitSubReqImpl  → out-of-class inline definition (for detail:: namespace)
  # ==================================================================
  proc subReqSigParams(e: CborRequestEntry): string {.compileTime.} =
    if e.argFields.len > 0:
      var first = true
      for (n, t) in e.argFields:
        if not first:
          result.add(", ")
        result.add(nimTypeToCppType(t) & " " & n)
        first = false

  proc subReqRetType(e: CborRequestEntry): string {.compileTime.} =
    "Result<" & payloadCppType(e.responseTypeName) & ">"

  proc emitSubReqDecl(e: CborRequestEntry): string {.compileTime.} =
    if e.responseTypeName.len == 0:
      return ""
    if e.returnsInterface.len > 0:
      return "  // TODO: nested create-instance from a sub-interface unsupported.\n"
    if not isEmittablePayload(e.responseTypeName):
      return
        "  // TODO: '" & e.apiName & "' return type '" & e.responseTypeName &
        "' not emittable.\n"
    if not isMethodSupported(e.apiName):
      return "  // TODO: '" & e.apiName & "' has unmappable parameter types.\n"
    let methodName = snakeToLowerCamel(e.apiName)
    result.add(
      "  " & subReqRetType(e) & " " & methodName & "(" & subReqSigParams(e) & ");\n"
    )

  proc emitSubReqImpl(e: CborRequestEntry, sub: string): string {.compileTime.} =
    if e.responseTypeName.len == 0:
      return ""
    if e.returnsInterface.len > 0 or not isEmittablePayload(e.responseTypeName) or
        not isMethodSupported(e.apiName):
      return ""
    let methodName = snakeToLowerCamel(e.apiName)
    let envName = e.responseTypeName & "Envelope"
    let voidResp = isVoidPayload(e.responseTypeName)
    let resTy = subReqRetType(e)
    let okExpr =
      if voidResp:
        resTy & "::ok()"
      else:
        resTy & "::ok(std::move(*env.ok))"
    let argsName = argsStructName(e.apiName)
    result.add(
      "inline " & resTy & " " & sub & "::" & methodName & "(" & subReqSigParams(e) &
        ") {\n"
    )
    if e.argFields.len > 0:
      var argsAssign = ""
      for (n, t) in e.argFields:
        argsAssign.add("  args." & n & " = " & n & ";\n")
      result.add("  " & argsName & " args;\n")
      result.add(argsAssign)
      result.add("  std::size_t cborLen = 0;\n")
      result.add("  try { cborLen = detail::cborEncodedSize(args); }\n")
      result.add("  catch (const std::exception& ex) {\n")
      result.add(
        "    return " & resTy &
          "::err(std::string(\"size pass failed: \") + ex.what());\n"
      )
      result.add("  }\n")
      result.add(
        "  void* inBuf = (cborLen > 0) ? " & p &
          "allocBuffer(static_cast<int32_t>(cborLen)) : nullptr;\n"
      )
      result.add(
        "  if (cborLen > 0 && !inBuf) return " & resTy &
          "::err(\"allocBuffer failed\");\n"
      )
      result.add("  try {\n")
      result.add(
        "    if (cborLen > 0) detail::cborEncodeInto(args, static_cast<std::uint8_t*>(inBuf), cborLen);\n"
      )
      result.add("  } catch (const std::exception& ex) {\n")
      result.add("    if (inBuf) { " & p & "freeBuffer(inBuf); }\n")
      result.add(
        "    return " & resTy &
          "::err(std::string(\"encode pass failed: \") + ex.what());\n"
      )
      result.add("  }\n")
      result.add("  std::string lastError;\n")
      result.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError, \"" & e.apiName &
          "\", inBuf, cborLen);\n"
      )
    else:
      result.add("  std::string lastError;\n")
      result.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError, \"" & e.apiName &
          "\", nullptr, 0);\n"
      )
    result.add("  if (status != 0) return " & resTy & "::err(lastError);\n")
    result.add("  if (resp.empty()) return " & resTy & "::err(\"empty response\");\n")
    result.add("  " & envName & " env;\n")
    result.add("  try {\n")
    result.add("    auto v = resp.view();\n")
    result.add(
      "    env = jsoncons::cbor::decode_cbor<" & envName & ">(v.begin(), v.end());\n"
    )
    result.add("  } catch (const std::exception& ex) {\n")
    result.add(
      "    return " & resTy & "::err(std::string(\"decode failed: \") + ex.what());\n"
    )
    result.add("  }\n")
    result.add("  if (env.err.has_value()) return " & resTy & "::err(*env.err);\n")
    result.add("  if (env.ok.has_value()) return " & okExpr & ";\n")
    result.add("  return " & resTy & "::err(\"malformed response envelope\");\n")
    result.add("}\n\n")

  # ==================================================================
  # Section 2: Sub-interface class declarations (signatures only).
  # Emitted in the library namespace right after the main Lib class so
  # they live under <library-name>, ahead of namespace detail.
  # Method implementations are emitted later inside namespace detail.
  # ==================================================================
  for ifaceName in subInterfaceNames:
    let sub = cppSubClassName(ifaceName)
    let subEvts = subEventsOf(ifaceName)
    let hasEvts = subEvts.len > 0
    h.add("// ---- " & sub & " — sub-instance wrapper of " & ifaceName & " ----\n")
    h.add("class " & sub & " {\n")
    h.add(" private:\n")
    h.add("  uint32_t ctx_ = 0;\n")
    for ev in subEvts:
      let dispType = ev.typeName & "Dispatcher"
      let dispMember = ev.apiName & "Dispatcher_"
      h.add(
        "  using " & dispType & " = detail::EventDispatcher<" & sub & ", detail::" &
          ev.typeName & "EventTraits>;\n"
      )
      h.add("  std::unique_ptr<" & dispType & "> " & dispMember & ";\n")
    h.add("\n public:\n")
    # Ctor/dtor/copy/move — declared here, defined out-of-class in detail::.
    h.add("  explicit " & sub & "(uint32_t ctx) noexcept;\n")
    h.add("  ~" & sub & "();\n")
    h.add("  " & sub & "(const " & sub & "&) = delete;\n")
    h.add("  " & sub & "& operator=(const " & sub & "&) = delete;\n")
    if hasEvts:
      h.add("  " & sub & "(" & sub & "&&) = delete;\n")
      h.add("  " & sub & "& operator=(" & sub & "&&) = delete;\n")
    else:
      h.add("  " & sub & "(" & sub & "&& o) noexcept;\n")
      h.add("  " & sub & "& operator=(" & sub & "&& o) noexcept;\n")
    h.add("  uint32_t ctx() const noexcept { return ctx_; }\n")
    h.add("  bool valid() const noexcept { return ctx_ != 0; }\n")
    h.add("  explicit operator bool() const noexcept { return ctx_ != 0; }\n")
    h.add("  void close() noexcept;\n")
    # Request method declarations.
    for e in requestEntries:
      if interfaceOwningRequestType(e.responseTypeName) == ifaceName:
        h.add(emitSubReqDecl(e))
    # Signal method declarations (one-way; routed by this instance's ctx_).
    for s in signalEntries:
      if interfaceOwningSignalType(s.typeName) == ifaceName:
        h.add(emitSignalDecl(s))
    # Event callback aliases + on/off declarations.
    for ev in subEvts:
      let camelBase = snakeToLowerCamel(ev.apiName)
      var pascal = camelBase
      if pascal.len > 0:
        pascal[0] = toUpperAscii(pascal[0])
      let cbAlias = ev.typeName & "Callback"
      h.add("  using " & cbAlias & " = std::function<void(" & sub & "&")
      for f in effectiveFields(ev.typeName):
        h.add(", " & eventCallbackParamType(f.nimType) & " " & f.name)
      h.add(")>;\n")
      h.add("  uint64_t on" & pascal & "(" & cbAlias & " fn) noexcept;\n")
      h.add("  void off" & pascal & "(uint64_t handle = 0) noexcept;\n")
    h.add("};\n\n")

  # ==================================================================
  # Section 3: Envelope + args structs (internal plumbing, after class)
  # ==================================================================
  var emittedEnvelopes: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if not isEmittablePayload(e.responseTypeName):
      continue
    if e.responseTypeName in emittedEnvelopes:
      continue
    emittedEnvelopes.add(e.responseTypeName)
    let envName = e.responseTypeName & "Envelope"
    # A `void` payload has no struct jsoncons can (de)serialise — the `ok`
    # slot holds the generic `jsoncons::json` so the empty `{}` map sent on
    # the wire still round-trips and `has_value()` reports success.
    # `void` -> generic json; a bare-primitive payload -> the simple type
    # (so `optional<bool>`, matching the unwrapped `Result<bool>` method).
    let okType =
      if isVoidPayload(e.responseTypeName):
        "jsoncons::json"
      else:
        payloadCppType(e.responseTypeName)
    h.add("struct " & envName & " {\n")
    h.add("  std::optional<" & okType & "> ok;\n")
    h.add("  std::optional<std::string> err;\n")
    h.add("};\n\n")

  for e in requestEntries:
    if e.argFields.len == 0:
      continue
    if not isMethodSupported(e.apiName):
      continue
    let an = argsStructName(e.apiName)
    if an.len == 0:
      continue
    h.add("struct " & an & " {\n")
    for (n, t) in e.argFields:
      h.add("  " & nimTypeToCppType(t) & " " & n & "{};\n")
    h.add("};\n\n")

  # ==================================================================
  # Section 4: JSONCONS macros (global scope)
  # ==================================================================
  h.add("} // namespace " & libName & "\n\n")

  # ---- Bytes json_type_traits ----
  # Forces CBOR byte-string (major type 2) for the public `Bytes` vector and
  # decodes a byte string back into it. Specialising is_json_type_traits_declared
  # is what disables jsoncons' built-in byte-container conv/encode paths (which
  # would otherwise encode std::vector<uint8_t> as a CBOR array): both the
  # json_conv_traits container partial-spec and the encode_traits container
  # specialisations are gated on !is_json_type_traits_declared, so this routes
  # all encode/decode through the traits below.
  block:
    let q = libName & "::Bytes"
    h.add("namespace jsoncons {\n")
    h.add(
      "template <> struct is_json_type_traits_declared<" & q &
        "> : public std::true_type {};\n"
    )
    h.add("template <typename Json>\n")
    h.add("struct json_type_traits<Json, " & q & "> {\n")
    h.add("  using allocator_type = typename Json::allocator_type;\n")
    h.add("  static bool is(const Json& j) noexcept { return j.is_byte_string(); }\n")
    h.add("  static " & q & " as(const Json& j) {\n")
    h.add("    auto bsv = j.as_byte_string_view();\n")
    h.add("    return " & q & "(bsv.begin(), bsv.end());\n")
    h.add("  }\n")
    h.add(
      "  static Json to_json(const " & q &
        "& v, const allocator_type& alloc = allocator_type()) {\n"
    )
    h.add(
      "    return jsoncons::make_obj_using_allocator<Json>(\n" &
        "        alloc, jsoncons::byte_string_arg, v, jsoncons::semantic_tag::none);\n"
    )
    h.add("  }\n")
    h.add("};\n")
    h.add("} // namespace jsoncons\n\n")

  if enumNames.len > 0:
    h.add(
      "namespace jsoncons {\n" & "template <typename Json, typename E>\n" &
        "struct broker_int_enum_traits {\n" & "  using value_type = E;\n" &
        "  using underlying = int32_t;\n" &
        "  static constexpr bool is_compatible = true;\n" &
        "  static bool is(const Json& j) noexcept {\n" &
        "    return j.template is<underlying>();\n" & "  }\n" &
        "  static value_type as(const Json& j) {\n" &
        "    return static_cast<value_type>(j.template as<underlying>());\n" & "  }\n" &
        "  static Json to_json(value_type v) {\n" &
        "    return Json(static_cast<underlying>(v));\n" & "  }\n" &
        "  template <typename Allocator>\n" &
        "  static Json to_json(value_type v, const Allocator&) {\n" &
        "    return to_json(v);\n" & "  }\n" & "};\n"
    )
    for name in enumNames:
      let q = libName & "::" & name
      h.add(
        "template <typename Json>\n" & "struct json_type_traits<Json, " & q & ">\n" &
          "    : public broker_int_enum_traits<Json, " & q & "> {};\n"
      )
    h.add("} // namespace jsoncons\n\n")

  for (name, fields) in payloadFields:
    if isTypeRegistered(name) and structHasKeyConv(lookupTypeEntry(name)):
      # Non-string-keyed map struct: auto-traits on the string-keyed wire
      # mirror, then custom traits on the public struct that convert keys.
      emitMemberTraitsMacro(h, libName & "::" & name & "__wire", name, fields)
      emitCppMapStructTraits(h, libName, name, lookupTypeEntry(name))
    else:
      emitMemberTraitsMacro(h, libName & "::" & name, name, fields)
  for envName in envelopeNames:
    emitEnvelopeTraits(h, libName & "::" & envName)
  if anyInstanceReturn:
    emitEnvelopeTraits(h, libName & "::__InstanceCtxEnvelope")
  for (name, fields) in argsFields:
    # Args structs aren't in the public registry under their `<Method>Args`
    # synthesised name; the loop falls through to `required = fieldNames`
    # and behaves identically to the previous _ALL_ emission. Pass the
    # name anyway so future arg-side Option support flips on for free.
    emitMemberTraitsMacro(h, libName & "::" & name, name, fields)
  if payloadFields.len > 0 or envelopeNames.len > 0 or argsFields.len > 0:
    h.add("\n")

  # ==================================================================
  # Section 5: detail encode helpers (need JSONCONS traits above)
  # ==================================================================
  h.add("namespace " & libName & " {\n")
  h.add("namespace detail {\n\n")

  # NimBuffer RAII wrapper for Nim-allocated buffers.
  h.add("class NimBuffer {\n")
  h.add(" public:\n")
  h.add("  NimBuffer() = default;\n")
  h.add("  NimBuffer(void* p, int32_t n) noexcept : p_(p), n_(n) {}\n")
  h.add(
    "  NimBuffer(NimBuffer&& o) noexcept : p_(o.p_), n_(o.n_) { o.p_ = nullptr; o.n_ = 0; }\n"
  )
  h.add("  NimBuffer& operator=(NimBuffer&& o) noexcept {\n")
  h.add(
    "    if (this != &o) { reset(); p_ = o.p_; n_ = o.n_; o.p_ = nullptr; o.n_ = 0; }\n"
  )
  h.add("    return *this;\n")
  h.add("  }\n")
  h.add("  NimBuffer(const NimBuffer&) = delete;\n")
  h.add("  NimBuffer& operator=(const NimBuffer&) = delete;\n")
  h.add("  ~NimBuffer() { reset(); }\n")
  h.add("  void reset() noexcept {\n")
  h.add("    if (p_) { " & p & "freeBuffer(p_); p_ = nullptr; n_ = 0; }\n")
  h.add("  }\n")
  h.add("  bool empty() const noexcept { return p_ == nullptr || n_ <= 0; }\n")
  h.add("  std::span<const std::uint8_t> view() const noexcept {\n")
  h.add("    return {static_cast<const std::uint8_t*>(p_),\n")
  h.add("            static_cast<std::size_t>(n_ > 0 ? n_ : 0)};\n")
  h.add("  }\n")
  h.add(" private:\n")
  h.add("  void* p_ = nullptr;\n")
  h.add("  int32_t n_ = 0;\n")
  h.add("};\n\n")

  h.add("struct CountingSink {\n")
  h.add("  using value_type = std::uint8_t;\n")
  h.add("  std::size_t* count;\n")
  h.add("  explicit CountingSink(std::size_t& c) noexcept : count(&c) {}\n")
  h.add("  void append(const std::uint8_t*, std::size_t n) noexcept { *count += n; }\n")
  h.add("  void push_back(std::uint8_t) noexcept { ++*count; }\n")
  h.add("  void flush() noexcept {}\n")
  h.add("};\n\n")
  h.add("struct SpanSink {\n")
  h.add("  using value_type = std::uint8_t;\n")
  h.add("  std::uint8_t* dst;\n")
  h.add("  std::size_t cap;\n")
  h.add("  std::size_t* pos;\n")
  h.add("  SpanSink(std::uint8_t* d, std::size_t c, std::size_t& p) noexcept\n")
  h.add("      : dst(d), cap(c), pos(&p) {}\n")
  h.add("  void append(const std::uint8_t* s, std::size_t n) noexcept {\n")
  h.add("    std::memcpy(dst + *pos, s, n); *pos += n;\n")
  h.add("  }\n")
  h.add("  void push_back(std::uint8_t b) noexcept { dst[(*pos)++] = b; }\n")
  h.add("  void flush() noexcept {}\n")
  h.add("};\n\n")
  # jsoncons 1.7.0 moved encode_traits into the `reflect` sub-namespace and
  # renamed the entry point from `encode(v, enc, ctx, ec)` to
  # `try_encode(alloc_set, v, enc)` returning `write_result`
  # (= `expected<void, std::error_code>`).
  h.add("template <class T>\n")
  h.add("std::size_t cborEncodedSize(const T& v) {\n")
  h.add("  std::size_t n = 0;\n")
  h.add("  jsoncons::cbor::basic_cbor_encoder<CountingSink> enc{CountingSink{n}};\n")
  h.add(
    "  auto result = jsoncons::reflect::encode_traits<T>::try_encode(\n" &
      "      jsoncons::make_alloc_set(), v, enc);\n"
  )
  h.add(
    "  if (!result) throw std::system_error(result.error(), \"cbor counting pass\");\n"
  )
  h.add("  enc.flush();\n")
  h.add("  return n;\n")
  h.add("}\n\n")
  h.add("template <class T>\n")
  h.add("void cborEncodeInto(const T& v, std::uint8_t* dst, std::size_t cap) {\n")
  h.add("  std::size_t pos = 0;\n")
  h.add(
    "  jsoncons::cbor::basic_cbor_encoder<SpanSink> enc{SpanSink{dst, cap, pos}};\n"
  )
  h.add(
    "  auto result = jsoncons::reflect::encode_traits<T>::try_encode(\n" &
      "      jsoncons::make_alloc_set(), v, enc);\n"
  )
  h.add(
    "  if (!result) throw std::system_error(result.error(), \"cbor write pass\");\n"
  )
  h.add("  enc.flush();\n")
  h.add("}\n\n")
  # rawCall / rawCallOwned — free functions in detail namespace.
  h.add("inline std::pair<int32_t, NimBuffer>\n")
  h.add(
    "rawCall(uint32_t ctx, std::string& lastError,\n" &
      "        const char* apiName, const std::uint8_t* in, std::size_t inLen) {\n"
  )
  h.add("  if (ctx == 0) {\n")
  h.add("    lastError = \"library context is not initialised\";\n")
  h.add("    return {-1, NimBuffer{}};\n")
  h.add("  }\n")
  h.add("  void* inBuf = nullptr;\n")
  h.add("  if (inLen > 0) {\n")
  h.add("    inBuf = " & p & "allocBuffer(static_cast<int32_t>(inLen));\n")
  h.add(
    "    if (!inBuf) { lastError = \"allocBuffer failed\"; return {-1, NimBuffer{}}; }\n"
  )
  h.add("    std::memcpy(inBuf, in, inLen);\n")
  h.add("  }\n")
  h.add("  void* respBuf = nullptr;\n")
  h.add("  int32_t respLen = 0;\n")
  h.add("  const int32_t status = " & p & "call(\n")
  h.add(
    "      ctx, apiName, inBuf, static_cast<int32_t>(inLen), &respBuf, &respLen);\n"
  )
  h.add("  NimBuffer resp{respBuf, respLen};\n")
  h.add("  if (status != 0) {\n")
  h.add("    if (status == " & $ApiStatusUnknownApi & " && !resp.empty()) {\n")
  h.add("      auto v = resp.view();\n")
  h.add("      lastError.assign(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("    } else {\n")
  h.add("      lastError = std::string(\"framework error: \") +\n")
  h.add("                  std::to_string(status);\n")
  h.add("    }\n")
  h.add("    return {status, std::move(resp)};\n")
  h.add("  }\n")
  h.add("  return {0, std::move(resp)};\n")
  h.add("}\n\n")

  h.add("inline std::pair<int32_t, NimBuffer>\n")
  h.add(
    "rawCallOwned(uint32_t ctx, std::string& lastError,\n" &
      "             const char* apiName, void* nimInBuf, std::size_t inLen) {\n"
  )
  h.add("  if (ctx == 0) {\n")
  h.add("    if (nimInBuf) " & p & "freeBuffer(nimInBuf);\n")
  h.add("    lastError = \"library context is not initialised\";\n")
  h.add("    return {-1, NimBuffer{}};\n")
  h.add("  }\n")
  h.add("  void* respBuf = nullptr;\n")
  h.add("  int32_t respLen = 0;\n")
  h.add("  const int32_t status = " & p & "call(\n")
  h.add(
    "      ctx, apiName, nimInBuf, static_cast<int32_t>(inLen), &respBuf, &respLen);\n"
  )
  h.add("  NimBuffer resp{respBuf, respLen};\n")
  h.add("  if (status != 0) {\n")
  h.add("    if (status == " & $ApiStatusUnknownApi & " && !resp.empty()) {\n")
  h.add("      auto v = resp.view();\n")
  h.add("      lastError.assign(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("    } else {\n")
  h.add("      lastError = std::string(\"framework error: \") +\n")
  h.add("                  std::to_string(status);\n")
  h.add("    }\n")
  h.add("    return {status, std::move(resp)};\n")
  h.add("  }\n")
  h.add("  return {0, std::move(resp)};\n")
  h.add("}\n\n")

  # ---- Async response trampoline ----
  # `callAsync` boxes a type-erased invoker (the typed user callback + its
  # decode step) as `userData`. One C-ABI trampoline reconstructs the box,
  # runs it with the raw (status, respBuf, respLen), then frees it. `respBuf`
  # is library-owned and valid only for the duration of the call.
  h.add("using AsyncInvoker = std::function<void(int32_t, const void*, int32_t)>;\n")
  h.add(
    "inline void asyncResponseTrampoline(void* userData, uint64_t /*reqId*/,\n" &
      "    int32_t status, const void* respBuf, int32_t respLen) {\n"
  )
  h.add("  std::unique_ptr<AsyncInvoker> inv(static_cast<AsyncInvoker*>(userData));\n")
  h.add("  if (inv && *inv) (*inv)(status, respBuf, respLen);\n")
  h.add("}\n\n")

  # ---- EventDispatcher template (CBOR-flavored) ----
  # One C-level subscription per event type, lazily registered on first
  # add() and unregistered when the last user callback is removed. User
  # callbacks are stored in a local map and fanned out under a snapshot
  # taken inside the trampoline. Mirrors native FFI EventDispatcher
  # semantics without the variadic C-arg shape (CBOR cb shape is fixed).
  h.add("template <typename Owner, typename Traits>\n")
  h.add("class EventDispatcher {\n")
  h.add(" public:\n")
  h.add("  using Callback = typename Traits::template Callback<Owner>;\n")
  h.add("  using EventStruct = typename Traits::EventStruct;\n\n")
  h.add("  explicit EventDispatcher(Owner& owner) noexcept : owner_(&owner) {}\n")
  h.add("  EventDispatcher(const EventDispatcher&) = delete;\n")
  h.add("  EventDispatcher& operator=(const EventDispatcher&) = delete;\n")
  h.add("  EventDispatcher(EventDispatcher&&) = delete;\n")
  h.add("  EventDispatcher& operator=(EventDispatcher&&) = delete;\n")
  h.add("  ~EventDispatcher() { clear(); }\n\n")
  h.add("  uint64_t add(Callback fn) noexcept {\n")
  h.add("    std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("    if (!owner_ || owner_->ctx() == 0 || !fn) return 0;\n")
  h.add("    if (nativeHandle_ == 0) {\n")
  h.add("      nativeHandle_ = Traits::registerWithC(\n")
  h.add(
    "          owner_->ctx(), &EventDispatcher::trampoline, static_cast<void*>(this));\n"
  )
  h.add("      if (nativeHandle_ == 0) return 0;\n")
  h.add("    }\n")
  h.add("    const uint64_t localHandle = nextLocalHandle_++;\n")
  h.add("    try {\n")
  h.add("      callbacks_.emplace(localHandle, std::move(fn));\n")
  h.add("      return localHandle;\n")
  h.add("    } catch (...) {\n")
  h.add("      if (callbacks_.empty() && nativeHandle_ != 0) {\n")
  h.add("        Traits::unregisterWithC(owner_->ctx(), nativeHandle_);\n")
  h.add("        nativeHandle_ = 0;\n")
  h.add("      }\n")
  h.add("      return 0;\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add("  void remove(uint64_t localHandle) noexcept {\n")
  h.add("    std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("    callbacks_.erase(localHandle);\n")
  h.add("    if (callbacks_.empty() && nativeHandle_ != 0) {\n")
  h.add("      if (owner_ && owner_->ctx() != 0)\n")
  h.add("        Traits::unregisterWithC(owner_->ctx(), nativeHandle_);\n")
  h.add("      nativeHandle_ = 0;\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add("  void clear() noexcept {\n")
  h.add("    std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("    callbacks_.clear();\n")
  h.add("    if (nativeHandle_ != 0) {\n")
  h.add("      if (owner_ && owner_->ctx() != 0)\n")
  h.add("        Traits::unregisterWithC(owner_->ctx(), nativeHandle_);\n")
  h.add("      nativeHandle_ = 0;\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add(" private:\n")
  h.add("  static void trampoline(uint32_t ctx, const char* /*eventName*/,\n")
  h.add("                         const void* payloadBuf, int32_t payloadLen,\n")
  h.add("                         void* userData) noexcept {\n")
  h.add("    auto* self = static_cast<EventDispatcher*>(userData);\n")
  h.add("    if (!self || !payloadBuf || payloadLen <= 0) return;\n")
  h.add("    EventStruct evt;\n")
  h.add("    try {\n")
  h.add("      std::span<const std::uint8_t> v{\n")
  h.add("          static_cast<const std::uint8_t*>(payloadBuf),\n")
  h.add("          static_cast<std::size_t>(payloadLen)};\n")
  h.add("      evt = jsoncons::cbor::decode_cbor<EventStruct>(v.begin(), v.end());\n")
  h.add("    } catch (...) { return; }\n")
  h.add("    self->deliver(ctx, evt);\n")
  h.add("  }\n\n")
  h.add("  void deliver(uint32_t ctx, const EventStruct& evt) noexcept {\n")
  h.add("    std::vector<Callback> snapshot;\n")
  h.add("    {\n")
  h.add("      std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("      if (!owner_ || ctx != owner_->ctx()) return;\n")
  h.add("      try {\n")
  h.add("        snapshot.reserve(callbacks_.size());\n")
  h.add(
    "        for (const auto& [id, fn] : callbacks_) if (fn) snapshot.push_back(fn);\n"
  )
  h.add("      } catch (...) { return; }\n")
  h.add("    }\n")
  h.add("    for (const auto& fn : snapshot) Traits::invoke(fn, *owner_, evt);\n")
  h.add("  }\n\n")
  h.add("  Owner* owner_ = nullptr;\n")
  h.add("  std::mutex mutex_;\n")
  h.add("  std::unordered_map<uint64_t, Callback> callbacks_;\n")
  h.add("  uint64_t nativeHandle_ = 0;\n")
  h.add("  uint64_t nextLocalHandle_ = 1;\n")
  h.add("};\n\n")

  # ---- Per-event Traits structs ----
  for ev in emittableEvents:
    let evFields = effectiveFields(ev.typeName)
    let evScalar = isScalarPayload(ev.typeName)
    # A `void` event has no struct jsoncons can decode — the payload-less
    # `{}` map is decoded through the generic `jsoncons::json`.
    let evStruct = if isVoidPayload(ev.typeName): "jsoncons::json" else: ev.typeName
    h.add("struct " & ev.typeName & "EventTraits {\n")
    h.add("  using EventStruct = " & evStruct & ";\n\n")
    # Callback alias: Owner&, then unpacked args.
    h.add("  template <typename Owner>\n")
    h.add("  using Callback = std::function<void(Owner&")
    for f in evFields:
      h.add(", " & eventCallbackParamType(f.nimType) & " " & f.name)
    h.add(")>;\n\n")
    h.add(
      "  static uint64_t registerWithC(uint32_t ctx,\n" &
        "      void (*cb)(uint32_t, const char*, const void*, int32_t, void*),\n" &
        "      void* userData) noexcept {\n"
    )
    h.add("    return " & p & "subscribe(ctx, \"" & ev.apiName & "\", cb, userData);\n")
    h.add("  }\n\n")
    h.add("  static void unregisterWithC(uint32_t ctx, uint64_t handle) noexcept {\n")
    h.add("    " & p & "unsubscribe(ctx, \"" & ev.apiName & "\", handle);\n")
    h.add("  }\n\n")
    h.add("  template <typename Owner>\n")
    h.add(
      "  static void invoke(const Callback<Owner>& fn, Owner& owner,\n" &
        "                     const " & evStruct & "& evt) noexcept {\n"
    )
    # Per-field setup statements (e.g. seq[string] -> vector<string_view>)
    # emitted BEFORE the try block so any temporary views the user callback
    # observes stay alive for the entire call.
    for f in evFields:
      let setup = eventCallbackInvokeSetup(f.name, f.nimType)
      if setup.len > 0:
        h.add(setup)
    h.add("    try {\n")
    h.add("      fn(owner")
    if evScalar:
      # Scalar payload: the decoded `evt` IS the value — pass it directly
      # (no `.value` member, EventStruct is the primitive alias itself).
      h.add(", evt")
    else:
      for f in evFields:
        h.add(", " & eventCallbackArgExpr(f.name, f.nimType))
    h.add(");\n")
    h.add("    } catch (...) {}\n")
    h.add("  }\n")
    h.add("};\n\n")

  h.add("} // namespace detail\n\n")

  # ==================================================================
  # Sub-interface out-of-class inline method implementations.
  # Emitted in the library namespace (same as the class declaration)
  # after detail:: is fully defined so EventDispatcher is complete.
  # ==================================================================
  for ifaceName in subInterfaceNames:
    let sub = cppSubClassName(ifaceName)
    let subEvts = subEventsOf(ifaceName)
    let hasEvts = subEvts.len > 0
    h.add("// ---- " & sub & " implementations ----\n")
    # Ctor
    if hasEvts:
      h.add("inline " & sub & "::" & sub & "(uint32_t ctx) noexcept\n")
      h.add("    : ctx_(ctx)\n")
      for ev in subEvts:
        let dispType = ev.typeName & "Dispatcher"
        let dispMember = ev.apiName & "Dispatcher_"
        h.add("    , " & dispMember & "(std::make_unique<" & dispType & ">(*this))\n")
      h.add("{}\n")
    else:
      h.add("inline " & sub & "::" & sub & "(uint32_t ctx) noexcept : ctx_(ctx) {}\n")
    # Dtor
    h.add("inline " & sub & "::~" & sub & "() { close(); }\n")
    # Move ctor/assign (event-free only)
    if not hasEvts:
      h.add(
        "inline " & sub & "::" & sub & "(" & sub &
          "&& o) noexcept : ctx_(o.ctx_) { o.ctx_ = 0; }\n"
      )
      h.add(
        "inline " & sub & "& " & sub & "::operator=(" & sub &
          "&& o) noexcept { if (this != &o) { close(); ctx_ = o.ctx_; o.ctx_ = 0; } return *this; }\n"
      )
    # close()
    h.add("inline void " & sub & "::close() noexcept {\n")
    for ev in subEvts:
      let dispMember = ev.apiName & "Dispatcher_"
      h.add("  if (" & dispMember & ") " & dispMember & "->clear();\n")
    h.add("  if (ctx_) { " & p & "releaseInstance(ctx_); ctx_ = 0; }\n")
    h.add("}\n")
    # Request method implementations.
    for e in requestEntries:
      if interfaceOwningRequestType(e.responseTypeName) == ifaceName:
        h.add(emitSubReqImpl(e, sub))
    # Signal method implementations (route to this instance via ctx_).
    for s in signalEntries:
      if interfaceOwningSignalType(s.typeName) == ifaceName:
        h.add(emitSignalImpl(s, sub))
    # Event on/off implementations.
    for ev in subEvts:
      let camelBase = snakeToLowerCamel(ev.apiName)
      var pascal = camelBase
      if pascal.len > 0:
        pascal[0] = toUpperAscii(pascal[0])
      let cbAlias = ev.typeName & "Callback"
      let dispMember = ev.apiName & "Dispatcher_"
      h.add(
        "inline uint64_t " & sub & "::on" & pascal & "(" & cbAlias &
          " fn) noexcept { return " & dispMember & "->add(std::move(fn)); }\n"
      )
      h.add(
        "inline void " & sub & "::off" & pascal &
          "(uint64_t handle) noexcept { if (handle == 0) " & dispMember &
          "->clear(); else " & dispMember & "->remove(handle); }\n"
      )
    h.add("\n")

  # ==================================================================
  # Section 6: Out-of-class inline Lib method definitions
  # ==================================================================

  # ---- Lifecycle ----
  # Constructor initializes one EventDispatcher per emittable event type.
  h.add("inline " & className & "::" & className & "()")
  if mainEvents.len > 0:
    h.add("\n")
    var first = true
    for ev in mainEvents:
      let dispatcherType = ev.typeName & "Dispatcher"
      let dispatcherMember = ev.apiName & "Dispatcher_"
      if first:
        h.add("    : ")
        first = false
      else:
        h.add("    , ")
      h.add(dispatcherMember & "(std::make_unique<" & dispatcherType & ">(*this))\n")
    h.add(" { " & p & "initialize(); }\n\n")
  else:
    h.add(" { " & p & "initialize(); }\n\n")
  h.add("inline " & className & "::~" & className & "() { shutdown(); }\n\n")
  h.add("inline std::string_view " & className & "::version() noexcept {\n")
  h.add("  return " & p & "version();\n")
  h.add("}\n\n")
  h.add("inline Result<void> " & className & "::createContext() {\n")
  h.add("  if (ctx_)\n")
  h.add("    return Result<void>::err(\"Context already created\");\n")
  h.add("  char* err = nullptr;\n")
  h.add("  ctx_ = " & p & "createContext(&err);\n")
  h.add("  if (ctx_ == 0) {\n")
  h.add("    if (err != nullptr) {\n")
  h.add("      std::string msg(err);\n")
  h.add("      " & p & "freeBuffer(err);\n")
  h.add("      return Result<void>::err(std::move(msg));\n")
  h.add("    }\n")
  h.add("    return Result<void>::err(\"createContext failed\");\n")
  h.add("  }\n")
  h.add("  return Result<void>::ok();\n")
  h.add("}\n\n")
  h.add(
    "inline bool " & className &
      "::validContext() const noexcept { return ctx_ != 0; }\n"
  )
  h.add(
    "inline " & className &
      "::operator bool() const noexcept { return validContext(); }\n"
  )
  h.add("inline uint32_t " & className & "::ctx() const noexcept { return ctx_; }\n\n")
  # shutdown clears all event dispatchers before calling C shutdown
  h.add("inline void " & className & "::shutdown() noexcept {\n")
  for ev in mainEvents:
    let dispatcherMember = ev.apiName & "Dispatcher_"
    h.add("  if (" & dispatcherMember & ") " & dispatcherMember & "->clear();\n")
  h.add("  if (ctx_) { " & p & "shutdown(ctx_); ctx_ = 0; }\n")
  h.add("}\n\n")

  # ---- Per-request method implementations ----
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if not ownsReqMain(e):
      continue
    let isInstance = e.returnsInterface.len > 0
    if not isInstance and not isEmittablePayload(e.responseTypeName):
      continue
    if not isMethodSupported(e.apiName):
      continue
    let methodName = snakeToLowerCamel(e.apiName)
    # reduced-A: a create-instance method decodes the shared uint-ctx envelope
    # and constructs the typed sub-wrapper from the returned ctx.
    let envName =
      if isInstance:
        "__InstanceCtxEnvelope"
      else:
        e.responseTypeName & "Envelope"
    let voidResp = (not isInstance) and isVoidPayload(e.responseTypeName)
    let subEv = isInstance and subHasEvents(e.returnsInterface)
    let resTy =
      if isInstance and subEv:
        "Result<std::unique_ptr<" & cppSubClassName(e.returnsInterface) & ">>"
      elif isInstance:
        "Result<" & cppSubClassName(e.returnsInterface) & ">"
      else:
        "Result<" & payloadCppType(e.responseTypeName) & ">"
    let okExpr =
      if isInstance and subEv:
        resTy & "::ok(std::make_unique<" & cppSubClassName(e.returnsInterface) &
          ">(static_cast<uint32_t>(*env.ok)))"
      elif isInstance:
        resTy & "::ok(" & cppSubClassName(e.returnsInterface) &
          "(static_cast<uint32_t>(*env.ok)))"
      elif voidResp:
        resTy & "::ok()"
      else:
        resTy & "::ok(std::move(*env.ok))"
    var sigParams = ""
    var argsAssign = ""
    let argsName = argsStructName(e.apiName)
    if e.argFields.len > 0:
      var first = true
      for (n, t) in e.argFields:
        if not first:
          sigParams.add(", ")
        sigParams.add(nimTypeToCppType(t) & " " & n)
        argsAssign.add("  args." & n & " = " & n & ";\n")
        first = false
    h.add(
      "inline " & resTy & " " & className & "::" & methodName & "(" & sigParams & ") {\n"
    )
    if e.argFields.len > 0:
      h.add("  " & argsName & " args;\n")
      h.add(argsAssign)
      h.add("  std::size_t cborLen = 0;\n")
      h.add("  try { cborLen = detail::cborEncodedSize(args); }\n")
      h.add("  catch (const std::exception& ex) {\n")
      h.add(
        "    return " & resTy &
          "::err(std::string(\"size pass failed: \") + ex.what());\n"
      )
      h.add("  }\n")
      h.add(
        "  void* inBuf = (cborLen > 0) ? " & p &
          "allocBuffer(static_cast<int32_t>(cborLen)) : nullptr;\n"
      )
      h.add("  if (cborLen > 0 && !inBuf)\n")
      h.add("    return " & resTy & "::err(\"allocBuffer failed\");\n")
      h.add("  try {\n")
      h.add(
        "    if (cborLen > 0) detail::cborEncodeInto(args, static_cast<std::uint8_t*>(inBuf), cborLen);\n"
      )
      h.add("  } catch (const std::exception& ex) {\n")
      h.add("    if (inBuf) { " & p & "freeBuffer(inBuf); }\n")
      h.add(
        "    return " & resTy &
          "::err(std::string(\"encode pass failed: \") + ex.what());\n"
      )
      h.add("  }\n")
      h.add("  std::string lastError;\n")
      h.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError, \"" & e.apiName &
          "\", inBuf, cborLen);\n"
      )
    else:
      h.add("  std::string lastError;\n")
      h.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError, \"" & e.apiName &
          "\", nullptr, 0);\n"
      )
    h.add("  if (status != 0)\n")
    h.add("    return " & resTy & "::err(lastError);\n")
    h.add("  if (resp.empty())\n")
    h.add("    return " & resTy & "::err(\"empty response\");\n")
    h.add("  " & envName & " env;\n")
    h.add("  try {\n")
    h.add("    auto v = resp.view();\n")
    h.add(
      "    env = jsoncons::cbor::decode_cbor<" & envName & ">(v.begin(), v.end());\n"
    )
    h.add("  } catch (const std::exception& ex) {\n")
    h.add(
      "    return " & resTy & "::err(std::string(\"decode failed: \") + ex.what());\n"
    )
    h.add("  }\n")
    h.add("  if (env.err.has_value())\n")
    h.add("    return " & resTy & "::err(*env.err);\n")
    h.add("  if (env.ok.has_value())\n")
    h.add("    return " & okExpr & ";\n")
    h.add("  return " & resTy & "::err(\"malformed response envelope\");\n")
    h.add("}\n\n")

    # ---- Async sibling definition (non-instance methods only) ----
    if not isInstance:
      let aResTy = "Result<" & payloadCppType(e.responseTypeName) & ">"
      let aOkExpr =
        if voidResp:
          aResTy & "::ok()"
        else:
          aResTy & "::ok(std::move(*env.ok))"
      let asyncSig =
        if sigParams.len > 0:
          sigParams & ", std::function<void(" & aResTy &
            ")> cb, std::chrono::milliseconds timeout"
        else:
          "std::function<void(" & aResTy & ")> cb, std::chrono::milliseconds timeout"
      # Returns 0 when queued (cb fires once later) or a negative code when NOT
      # queued (cb does NOT fire): asyncAgain (-6) = EAGAIN, asyncBadContext (-5),
      # asyncNoCallback (-7), asyncEncodeFailed (-1). This mirrors the raw ABI so
      # callers can implement backpressure (retry on -6) without the callback
      # being consumed by a transient failure.
      h.add(
        "inline int32_t " & className & "::" & methodName & "Async(" & asyncSig & ") {\n"
      )
      h.add("  if (!cb) return asyncNoCallback;\n")
      if e.argFields.len > 0:
        h.add("  " & argsName & " args;\n")
        h.add(argsAssign)
        h.add("  std::size_t cborLen = 0;\n")
        h.add("  try { cborLen = detail::cborEncodedSize(args); }\n")
        h.add("  catch (const std::exception&) { return asyncEncodeFailed; }\n")
        h.add(
          "  void* inBuf = (cborLen > 0) ? " & p &
            "allocBuffer(static_cast<int32_t>(cborLen)) : nullptr;\n"
        )
        h.add("  if (cborLen > 0 && !inBuf) return asyncEncodeFailed;\n")
        h.add("  try {\n")
        h.add(
          "    if (cborLen > 0) detail::cborEncodeInto(args, static_cast<std::uint8_t*>(inBuf), cborLen);\n"
        )
        h.add("  } catch (const std::exception&) {\n")
        h.add("    if (inBuf) { " & p & "freeBuffer(inBuf); }\n")
        h.add("    return asyncEncodeFailed;\n")
        h.add("  }\n")
      else:
        h.add("  void* inBuf = nullptr;\n")
        h.add("  std::size_t cborLen = 0;\n")
      # Box the typed decode + user callback as the opaque correlation handle.
      h.add(
        "  auto* inv = new detail::AsyncInvoker(\n" &
          "      [cb = std::move(cb)](int32_t status, const void* respBuf, int32_t respLen) {\n"
      )
      h.add("    if (status != 0) {\n")
      h.add("      std::string lastError;\n")
      h.add(
        "      if (status == " & $ApiStatusUnknownApi & " && respBuf && respLen > 0)\n"
      )
      h.add(
        "        lastError.assign(reinterpret_cast<const char*>(respBuf), static_cast<size_t>(respLen));\n"
      )
      h.add("      else if (status == " & $ApiStatusTimeout & ")\n")
      h.add("        lastError = \"request timed out\";\n")
      h.add("      else if (status == " & $ApiStatusShutdown & ")\n")
      h.add("        lastError = \"library shut down\";\n")
      h.add("      else\n")
      h.add(
        "        lastError = std::string(\"framework error: \") + std::to_string(status);\n"
      )
      h.add("      cb(" & aResTy & "::err(lastError)); return;\n")
      h.add("    }\n")
      h.add("    if (!respBuf || respLen <= 0) {\n")
      h.add("      cb(" & aResTy & "::err(\"empty response\")); return;\n")
      h.add("    }\n")
      h.add("    " & envName & " env;\n")
      h.add("    try {\n")
      h.add("      const auto* p0 = static_cast<const std::uint8_t*>(respBuf);\n")
      h.add(
        "      env = jsoncons::cbor::decode_cbor<" & envName & ">(p0, p0 + respLen);\n"
      )
      h.add("    } catch (const std::exception& ex) {\n")
      h.add(
        "      cb(" & aResTy &
          "::err(std::string(\"decode failed: \") + ex.what())); return;\n"
      )
      h.add("    }\n")
      h.add(
        "    if (env.err.has_value()) { cb(" & aResTy & "::err(*env.err)); return; }\n"
      )
      h.add("    if (env.ok.has_value()) { cb(" & aOkExpr & "); return; }\n")
      h.add("    cb(" & aResTy & "::err(\"malformed response envelope\"));\n")
      h.add("  });\n")
      h.add("  // chrono -> ABI ms: <= 0 means infinite (ABI 0); clamp to u32.\n")
      h.add("  const auto __tc = timeout.count();\n")
      h.add(
        "  const uint32_t timeoutMs = __tc <= 0 ? 0u\n" &
          "      : (__tc > 0xFFFFFFFFll ? 0xFFFFFFFFu : static_cast<uint32_t>(__tc));\n"
      )
      h.add(
        "  const int32_t rc = " & p & "callAsync(ctx_, \"" & e.apiName &
          "\", inBuf, static_cast<int32_t>(cborLen),\n" &
          "      asyncReqId_.fetch_add(1, std::memory_order_relaxed) + 1, timeoutMs,\n" &
          "      &detail::asyncResponseTrampoline, inv);\n"
      )
      h.add("  if (rc != 0) {\n")
      h.add("    // Not queued — the library frees inBuf and will NOT invoke the\n")
      h.add("    // callback. Drop the box (cb unconsumed) and report rc so the\n")
      h.add("    // caller can retry on asyncAgain (-6) or handle the rejection.\n")
      h.add("    delete inv;\n")
      h.add("    return rc;\n")
      h.add("  }\n")
      h.add("  return 0;\n")
      h.add("}\n\n")

      # ---- Future-returning definition (std::promise bridge over Async) ----
      var argNamesCsv = ""
      for (n, _) in e.argFields:
        argNamesCsv.add(n & ", ")
      let futureSig =
        if sigParams.len > 0:
          sigParams & ", std::chrono::milliseconds timeout"
        else:
          "std::chrono::milliseconds timeout"
      h.add(
        "inline std::future<" & aResTy & "> " & className & "::" & methodName & "Future(" &
          futureSig & ") {\n"
      )
      h.add("  auto prom = std::make_shared<std::promise<" & aResTy & ">>();\n")
      h.add("  auto fut = prom->get_future();\n")
      h.add("  // Backpressure by WAITING, not erroring: block briefly on the window\n")
      h.add(
        "  // semaphore when asyncQueueDepth calls are in flight. Released in the\n"
      )
      h.add("  // completion callback (below) or inline on a rejected call.\n")
      h.add("  asyncWindow_.acquire();\n")
      h.add(
        "  // The promise is fulfilled from exactly one place: the delivery-thread\n"
      )
      h.add(
        "  // callback when the call is queued (rc == 0), or inline below when it\n"
      )
      h.add("  // is rejected (rc != 0 — the callback never fires).\n")
      h.add(
        "  const int32_t rc = " & methodName & "Async(" & argNamesCsv & "[this, prom](" &
          aResTy & " __r) {\n" & "      asyncWindow_.release();\n" &
          "      prom->set_value(std::move(__r));\n" & "  }, timeout);\n"
      )
      h.add("  if (rc != 0) {\n")
      h.add("    asyncWindow_.release();\n")
      h.add("    // asyncAgain can still surface here when callback-style fooAsync\n")
      h.add("    // callers share the same context window outside the semaphore.\n")
      h.add("    prom->set_value(" & aResTy & "::err(\n")
      h.add("        rc == asyncAgain ? std::string(\"EAGAIN: async window full\")\n")
      h.add(
        "                         : std::string(\"request not queued: rc=\") + std::to_string(rc)));\n"
      )
      h.add("  }\n")
      h.add("  return fut;\n")
      h.add("}\n\n")

  # ---- Per-signal method implementations (one-way, slot-free `_call`) ----
  for s in signalEntries:
    if not ownsSigMain(s):
      continue
    h.add(emitSignalImpl(s, className))

  # ---- Per-event on/off implementations (delegate to dispatcher) ----
  for ev in mainEvents:
    let camelBase = snakeToLowerCamel(ev.apiName)
    var pascal = camelBase
    if pascal.len > 0:
      pascal[0] = toUpperAscii(pascal[0])
    let callbackAlias = ev.typeName & "Callback"
    let onName = "on" & pascal
    let offName = "off" & pascal
    let dispatcherMember = ev.apiName & "Dispatcher_"

    h.add(
      "inline uint64_t " & className & "::" & onName & "(" & callbackAlias &
        " fn) noexcept {\n"
    )
    h.add("  return " & dispatcherMember & "->add(std::move(fn));\n")
    h.add("}\n\n")

    h.add(
      "inline void " & className & "::" & offName & "(uint64_t handle) noexcept {\n"
    )
    h.add("  if (handle == 0) " & dispatcherMember & "->clear();\n")
    h.add("  else " & dispatcherMember & "->remove(handle);\n")
    h.add("}\n\n")

  # ---- Discovery implementations ----
  h.add("inline std::string " & className & "::listApis() {\n")
  h.add("  void* buf = nullptr;\n")
  h.add("  int32_t len = 0;\n")
  h.add("  const int32_t status = " & p & "listApis(&buf, &len);\n")
  h.add("  detail::NimBuffer nb{buf, len};\n")
  # listApis/getSchema have no error channel back to the caller beyond an
  # empty return — the old `lastError_ = ...` writes were dead state on a
  # member that has no public accessor. Dropped: returning {} is enough.
  h.add("  if (status != 0) return {};\n")
  h.add("  if (nb.empty()) return {};\n")
  h.add("  auto v = nb.view();\n")
  h.add("  return std::string(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("}\n\n")
  h.add("inline std::string " & className & "::getSchema() {\n")
  h.add("  void* buf = nullptr;\n")
  h.add("  int32_t len = 0;\n")
  h.add("  const int32_t status = " & p & "getSchema(&buf, &len);\n")
  h.add("  detail::NimBuffer nb{buf, len};\n")
  h.add("  if (status != 0) return {};\n")
  h.add("  if (nb.empty()) return {};\n")
  h.add("  auto v = nb.view();\n")
  h.add("  return std::string(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("}\n\n")

  h.add("} // namespace " & libName & "\n\n")
  h.add("#endif // " & guardName & "\n")

  try:
    writeFile(headerPath, h)
  except IOError:
    error(
      "Failed to write generated CBOR C++ header '" & headerPath & "': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
