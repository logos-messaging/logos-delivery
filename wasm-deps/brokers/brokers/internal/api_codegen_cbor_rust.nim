## Generated Rust wrapper for the CBOR FFI surface.
##
## The generated `<lib>_rs/` Cargo crate ships alongside the shared library
## and uses `ciborium` + `serde` for CBOR encode/decode of typed payloads
## plus `serde_json` for the discovery endpoints (`list_apis`, `get_schema`)
## which return JSON. Foreign Rust projects only need the three crate
## dependencies — no other tooling.
##
## The wrapper emits typed `#[derive(Serialize, Deserialize)]` structs for
## each registered request response, request args, and event payload type,
## plus per-request methods on the libname-PascalCase wrapper that
## CBOR-encode the args, dispatch through the C ABI, and decode the
## response envelope into a `Result<T, String>`. Per-event
## `on_<name>(callback) -> u64` methods register a typed closure; the
## library holds a `Mutex<HashMap<u64, ...>>` per event keyed by handle so
## the trampoline can dispatch back to user code, mirroring the C++
## `EventDispatcher` GC anchor.
##
## Type-matrix coverage:
##   - Primitives: bool, int/intN, uint/uintN/byte, float/floatN, string,
##     char.
##   - Enums (atkEnum) → `#[repr(i32)]` Rust enums with `From<i32>` impls.
##   - Distinct/Alias (atkDistinct/atkAlias) → Rust `pub type X = Y;`
##     aliases of the resolved underlying type.
##   - Registered objects → `#[derive(Serialize, Deserialize, Clone, Debug,
##     Default)] pub struct` with typed fields.
##   - Composite types: seq[T], array[N, T] (typed as Vec<T>),
##     including seq[byte] and seq[<object>]; nested objects.
## Unmappable types still produce a TODO stub so the wrapper compiles.

{.push raises: [].}

import std/[macros, strutils, tables]
import ./api_common, ./api_schema
import ./helper/broker_utils # reduced-A: per-interface partitioning

# ---------------------------------------------------------------------------
# Nim → Rust type mapping (registry-aware)
# ---------------------------------------------------------------------------

const rustPrimMap = {
  "bool": "bool",
  "string": "String",
  "char": "String",
  "int": "i32",
  "int8": "i8",
  "int16": "i16",
  "int32": "i32",
  "int64": "i64",
  "uint": "u32",
  "uint8": "u8",
  "uint16": "u16",
  "uint32": "u32",
  "uint64": "u64",
  "byte": "u8",
  "float": "f64",
  "float32": "f32",
  "float64": "f64",
}.toTable

proc isRustPrimitive(nimType: string): bool {.compileTime.} =
  nimType.strip() in rustPrimMap

proc primRustHint(nimType: string): string {.compileTime.} =
  rustPrimMap.getOrDefault(nimType.strip(), "")

proc unwrapBracket(s, head: string): string {.compileTime.} =
  let t = s.strip()
  t[head.len + 1 .. ^2].strip()

proc parseArrayInner(s: string): string {.compileTime.} =
  let inner = s.strip()[6 ..^ 2]
  let comma = inner.find(',')
  if comma < 0:
    return ""
  inner[comma + 1 .. ^1].strip()

proc nimTypeToRustHint*(nimType: string): string {.compileTime.} =
  ## Recursive Nim → Rust type. Falls back to "" for types we can't yet map.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if isRustPrimitive(t):
    return primRustHint(t)
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = nimTypeToRustHint(unwrapBracket(t, "seq"))
    return
      if inner.len > 0:
        "Vec<" & inner & ">"
      else:
        "Vec<serde_cbor_value::Value>"
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToRustHint(elem)
    return
      if inner.len > 0:
        "Vec<" & inner & ">"
      else:
        "Vec<serde_cbor_value::Value>"
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToRustHint(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "Option<" & inner & ">"
      else:
        "Option<serde_cbor_value::Value>"
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject, atkEnum:
      return t
    of atkAlias, atkDistinct:
      # Recurse via outer mapper so distinct/alias over compound types
      # (e.g. `distinct seq[byte]`) maps to `Vec<u8>` rather than the "" fallback.
      return nimTypeToRustHint(resolveUnderlyingType(t))
  ""

proc nimTypeToRustDefaultHint*(nimType: string): string {.compileTime.} =
  ## Returns a Rust default expression for a struct field initializer
  ## (used in `Default::default()` derivations — the generated structs
  ## use `#[derive(Default)]` so this is mainly informational, but
  ## emitted as part of TODO comments).
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  case t
  of "bool":
    return "false"
  of "string", "char":
    return "String::new()"
  of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "byte", "uint16",
      "uint32", "uint64":
    return "0"
  of "float32", "float", "float64":
    return "0.0"
  else:
    discard
  if lower.startsWith("seq[") or lower.startsWith("array["):
    return "Vec::new()"
  if lower.startsWith("option["):
    return "None"
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return "Default::default()"
    of atkEnum:
      return t & "::default()"
    of atkAlias, atkDistinct:
      return nimTypeToRustDefaultHint(resolveUnderlyingType(t))
  "Default::default()"

proc isRustMappable*(nimType: string): bool {.compileTime.} =
  nimTypeToRustHint(nimType).len > 0

# ---------------------------------------------------------------------------
# File emission
# ---------------------------------------------------------------------------

{.pop.}

proc cborRustClassName(libName: string): string {.compileTime.} =
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

proc rustSubStructName(iface: string): string {.compileTime.} =
  ## Wrapper struct name for a sub-interface: strip a leading `I` before an
  ## uppercase letter (IWidget -> Widget), else use the name as-is.
  if iface.len > 1 and iface[0] == 'I' and iface[1] in {'A' .. 'Z'}:
    iface[1 ..^ 1]
  else:
    iface

proc generateCborRustFile*(
    outDir: string,
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
    mainClass: string = "",
) {.compileTime, raises: [].} =
  ## Writes the Rust wrapper crate (Cargo.toml + src/lib.rs) for a
  ## CBOR-mode library under `<outDir>/<libName>_rs/`.
  ensureGeneratedOutputDir(outDir)

  # reduced-A: per-interface partition. Sub-interface names are derived from the
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

  var subInterfaceNames: seq[string] = @[]
  if mainClass.len > 0:
    for e in requestEntries:
      let o = interfaceOwningRequestType(e.responseTypeName)
      if o.len > 0 and o != mainClass and o notin subInterfaceNames:
        subInterfaceNames.add(o)
  let crateDir =
    if outDir.len > 0:
      outDir & "/" & libName & "_rs"
    else:
      libName & "_rs"
  let srcDir = crateDir & "/src"
  ensureGeneratedOutputDir(crateDir)
  ensureGeneratedOutputDir(srcDir)

  let className = cborRustClassName(libName)
  let p = libName & "_"

  # ---------------------- Cargo.toml ----------------------
  var cargo = "# Generated by nim-brokers CBOR FFI Rust codegen — do not edit.\n"
  cargo.add("[package]\n")
  cargo.add("name = \"" & libName & "\"\n")
  cargo.add("version = \"0.1.0\"\n")
  cargo.add("edition = \"2021\"\n")
  cargo.add("rust-version = \"1.75\"\n\n")
  cargo.add("[lib]\n")
  cargo.add("name = \"" & libName & "\"\n")
  cargo.add("crate-type = [\"rlib\"]\n\n")
  cargo.add("[dependencies]\n")
  cargo.add("ciborium = \"0.2\"\n")
  cargo.add("serde = { version = \"1\", features = [\"derive\"] }\n")
  cargo.add("serde_bytes = \"0.11\"\n")
  cargo.add("serde_json = \"1\"\n")
  try:
    writeFile(crateDir & "/Cargo.toml", cargo)
  except IOError:
    error(
      "Failed to write generated CBOR Rust Cargo.toml '" & crateDir & "/Cargo.toml': " &
        getCurrentExceptionMsg()
    )

  # ---------------------- src/lib.rs ----------------------
  var rs = "// Generated by nim-brokers CBOR FFI Rust codegen — do not edit.\n"
  rs.add("//\n")
  rs.add("// Rust wrapper around the C ABI declared in `" & libName & ".h`.\n")
  rs.add("// Requires Rust 1.75+ and the `ciborium` + `serde` + `serde_json` crates.\n")
  rs.add("//\n")
  rs.add("// Public API surface (auto-generated from broker declarations):\n")
  rs.add("//   pub fn version() -> String  (associated)\n")
  rs.add("//   pub fn new() -> Self\n")
  rs.add("//   pub fn create_context(&mut self) -> Result<()>\n")
  rs.add("//   pub fn valid_context(&self) -> bool\n")
  rs.add("//   pub fn shutdown(&mut self)\n")
  rs.add("//   pub fn ctx(&self) -> u32\n")
  rs.add("//\n")
  rs.add("// Each request method returns Result<T, String>. Each event has\n")
  rs.add("// on_<name>(callback) -> u64 and off_<name>(handle).\n")
  rs.add("//\n")
  for e in requestEntries:
    var sigParams = ""
    for i, (n, t) in e.argFields.pairs:
      if i > 0:
        sigParams.add(", ")
      sigParams.add(n & ": " & nimTypeToRustHint(t))
    rs.add(
      "//   " & e.apiName & "(" & sigParams & ") -> Result<" & e.responseTypeName & ">\n"
    )
  for ev in eventEntries:
    rs.add("//   on_" & ev.apiName & "(callback) -> u64\n")
    rs.add("//   off_" & ev.apiName & "(handle)\n")
  rs.add("\n")

  rs.add("#![allow(non_camel_case_types)]\n")
  rs.add("#![allow(non_snake_case)]\n")
  rs.add("#![allow(non_upper_case_globals)]\n")
  rs.add("#![allow(dead_code)]\n")
  rs.add("#![allow(unused_imports)]\n")
  rs.add("#![allow(clippy::missing_safety_doc)]\n\n")

  rs.add("use serde::{Deserialize, Serialize};\n")
  rs.add("use std::collections::HashMap;\n")
  rs.add("use std::ffi::{CStr, CString};\n")
  rs.add("use std::os::raw::{c_char, c_int, c_void};\n")
  rs.add("use std::sync::{Arc, Mutex, OnceLock};\n\n")

  # ---- extern "C" bindings ---------------------------------------------
  rs.add("// -------- C ABI bindings --------\n\n")
  rs.add("extern \"C\" {\n")
  rs.add("    fn " & p & "version() -> *const c_char;\n")
  rs.add("    fn " & p & "initialize();\n")
  rs.add("    fn " & p & "createContext(err: *mut *const c_char) -> u32;\n")
  rs.add("    fn " & p & "shutdown(ctx: u32) -> i32;\n")
  rs.add("    fn " & p & "releaseInstance(ctx: u32) -> i32;\n")
  rs.add("    fn " & p & "allocBuffer(size: i32) -> *mut c_void;\n")
  rs.add("    fn " & p & "freeBuffer(p: *mut c_void);\n")
  rs.add("    fn " & p & "call(\n")
  rs.add("        ctx: u32,\n")
  rs.add("        api_name: *const c_char,\n")
  rs.add("        in_buf: *const c_void,\n")
  rs.add("        in_len: i32,\n")
  rs.add("        out_buf: *mut *mut c_void,\n")
  rs.add("        out_len: *mut i32,\n")
  rs.add("    ) -> i32;\n")
  rs.add("    fn " & p & "subscribe(\n")
  rs.add("        ctx: u32,\n")
  rs.add("        event_name: *const c_char,\n")
  rs.add("        cb: EventCb,\n")
  rs.add("        user_data: *mut c_void,\n")
  rs.add("    ) -> u64;\n")
  rs.add(
    "    fn " & p &
      "unsubscribe(ctx: u32, event_name: *const c_char, handle: u64) -> i32;\n"
  )
  rs.add(
    "    fn " & p & "listApis(out_buf: *mut *mut c_void, out_len: *mut i32) -> i32;\n"
  )
  rs.add(
    "    fn " & p & "getSchema(out_buf: *mut *mut c_void, out_len: *mut i32) -> i32;\n"
  )
  rs.add("}\n\n")

  rs.add(
    "pub type EventCb = unsafe extern \"C\" fn(ctx: u32, name: *const c_char, buf: *const c_void, buf_len: i32, ud: *mut c_void);\n\n"
  )

  # ---- Result envelope -------------------------------------------------
  rs.add("/// Mirror of Nim's `Result[T, string]` envelope on the wire.\n")
  rs.add("#[derive(Debug, Clone)]\n")
  rs.add("pub struct Result<T> {\n")
  rs.add("    inner: ::std::result::Result<T, String>,\n")
  rs.add("}\n\n")
  rs.add("impl<T> Result<T> {\n")
  rs.add("    pub fn ok(value: T) -> Self { Self { inner: Ok(value) } }\n")
  rs.add(
    "    pub fn err<S: Into<String>>(msg: S) -> Self { Self { inner: Err(msg.into()) } }\n"
  )
  rs.add("    pub fn is_ok(&self) -> bool { self.inner.is_ok() }\n")
  rs.add("    pub fn is_err(&self) -> bool { self.inner.is_err() }\n")
  rs.add("    pub fn value(&self) -> Option<&T> { self.inner.as_ref().ok() }\n")
  rs.add(
    "    pub fn error(&self) -> Option<&str> { self.inner.as_ref().err().map(|s| s.as_str()) }\n"
  )
  rs.add(
    "    pub fn into_result(self) -> ::std::result::Result<T, String> { self.inner }\n"
  )
  rs.add("}\n\n")

  # ---- Generated payload types -----------------------------------------
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
  # Its CBOR wire value is a bare scalar; the Rust surface uses the
  # `pub type X = <prim>` alias directly. Such a type is an emittable
  # request response / event payload despite having no object fields.
  proc isScalarPayload(name: string): bool {.compileTime.} =
    name.len > 0 and isTypeRegistered(name) and
      lookupTypeEntry(name).kind in {atkAlias, atkDistinct} and
      primRustHint(resolveUnderlyingType(name)).len > 0

  proc isEmittablePayload(name: string): bool {.compileTime.} =
    name in objectNames or isScalarPayload(name)

  if enumNames.len > 0 or aliasNames.len > 0 or objectNames.len > 0:
    rs.add("// -------- Generated payload types --------\n\n")

  # Enums.
  for name in enumNames:
    let entry = lookupTypeEntry(name)
    rs.add("#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]\n")
    rs.add("#[repr(i32)]\n")
    rs.add("#[serde(into = \"i32\", from = \"i32\")]\n")
    rs.add("pub enum " & name & " {\n")
    if entry.enumValues.len == 0:
      rs.add("    Unknown = 0,\n")
    else:
      for v in entry.enumValues:
        rs.add("    " & v.name & " = " & $v.ordinal & ",\n")
    rs.add("}\n\n")
    rs.add("impl Default for " & name & " {\n")
    if entry.enumValues.len == 0:
      rs.add("    fn default() -> Self { " & name & "::Unknown }\n")
    else:
      rs.add(
        "    fn default() -> Self { " & name & "::" & entry.enumValues[0].name & " }\n"
      )
    rs.add("}\n\n")
    rs.add("impl From<i32> for " & name & " {\n")
    rs.add("    fn from(v: i32) -> Self {\n")
    rs.add("        match v {\n")
    for v in entry.enumValues:
      rs.add("            " & $v.ordinal & " => " & name & "::" & v.name & ",\n")
    rs.add("            _ => Self::default(),\n")
    rs.add("        }\n")
    rs.add("    }\n")
    rs.add("}\n\n")
    rs.add("impl From<" & name & "> for i32 {\n")
    rs.add("    fn from(v: " & name & ") -> Self { v as i32 }\n")
    rs.add("}\n\n")

  # Distinct / alias.
  for name in aliasNames:
    let underlying = resolveUnderlyingType(name)
    let pyU = primRustHint(underlying)
    if pyU.len == 0:
      rs.add(
        "// TODO: alias '" & name & "' resolves to '" & underlying &
          "' which has no Rust primitive mapping\n\n"
      )
      continue
    rs.add("pub type " & name & " = " & pyU & ";\n\n")

  # Objects.
  for name in objectNames:
    let entry = lookupTypeEntry(name)
    rs.add("#[derive(Debug, Clone, Default, Serialize, Deserialize)]\n")
    rs.add("pub struct " & name & " {\n")
    var anyField = false
    for f in entry.fields:
      let hint = nimTypeToRustHint(f.nimType)
      if hint.len == 0:
        rs.add("    // TODO: Nim type '" & f.nimType & "' not yet mappable\n")
        continue
      # Map seq[byte] to serde_bytes::ByteBuf for compact CBOR encoding.
      let useByteBuf = f.nimType.strip().toLowerAscii() == "seq[byte]"
      if useByteBuf:
        rs.add("    #[serde(with = \"serde_bytes\")]\n")
      rs.add("    pub " & f.name & ": " & hint & ",\n")
      anyField = true
    if not anyField:
      # Zero-field payload (a `void` broker type). `#[serde(skip)]` keeps the
      # placeholder field off the wire so the struct round-trips the empty
      # `{}` CBOR map a payload-less request / event carries.
      rs.add("    #[serde(skip)]\n")
      rs.add("    _phantom: (),\n")
    rs.add("}\n\n")

  # ---- Lib struct ------------------------------------------------------
  rs.add("// -------- Lib struct --------\n\n")

  # CBOR event dispatch via user_data. Each on_X registration leaks a
  # Box<Arc<closure>> via Box::into_raw so its pointer is stable for
  # the C broker to hold as user_data. The shared trampoline retrieves
  # and invokes exactly one closure per emit — no global map, no
  # fan-out, no cross-context leakage. Holders are tracked per-ctx and
  # dropped together on shutdown (the broker docs say in-flight
  # callbacks complete after off returns, so eager Drop on off would
  # UAF; a per-ctx-shutdown free is the safe upper bound).
  rs.add("type CborEventHandler = Arc<dyn Fn(&[u8]) + Send + Sync + 'static>;\n\n")
  rs.add("struct CborHolderEntry { ctx: u32, ptr: *mut c_void }\n")
  rs.add("unsafe impl Send for CborHolderEntry {}\n")
  rs.add("unsafe impl Sync for CborHolderEntry {}\n\n")
  rs.add(
    "static CBOR_EVENT_HOLDERS: OnceLock<Mutex<Vec<CborHolderEntry>>> = OnceLock::new();\n"
  )
  rs.add("fn cbor_event_holders() -> &'static Mutex<Vec<CborHolderEntry>> {\n")
  rs.add("    CBOR_EVENT_HOLDERS.get_or_init(|| Mutex::new(Vec::new()))\n")
  rs.add("}\n\n")
  rs.add("fn drop_cbor_event_holders_for_ctx(ctx: u32) {\n")
  rs.add("    let mut g = cbor_event_holders().lock().unwrap();\n")
  rs.add("    let mut keep: Vec<CborHolderEntry> = Vec::with_capacity(g.len());\n")
  rs.add("    for e in g.drain(..) {\n")
  rs.add("        if e.ctx == ctx {\n")
  rs.add(
    "            unsafe { drop(Box::from_raw(e.ptr as *mut CborEventHandler)); }\n"
  )
  rs.add("        } else { keep.push(e); }\n")
  rs.add("    }\n")
  rs.add("    *g = keep;\n")
  rs.add("}\n\n")

  rs.add(
    "/// Pythonic / C++-equivalent wrapper around the `" & libName & "` library.\n"
  )
  rs.add("pub struct " & className & " {\n")
  rs.add("    ctx: u32,\n")
  rs.add("}\n\n")

  rs.add("impl " & className & " {\n")
  rs.add("    /// Static semver string baked into the shared library.\n")
  rs.add("    pub fn version() -> String {\n")
  rs.add("        unsafe {\n")
  rs.add("            let p = " & p & "version();\n")
  rs.add(
    "            if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }\n"
  )
  rs.add("        }\n")
  rs.add("    }\n\n")

  rs.add("    pub fn new() -> Self {\n")
  rs.add("        unsafe { " & p & "initialize(); }\n")
  rs.add("        Self { ctx: 0 }\n")
  rs.add("    }\n\n")

  rs.add("    pub fn create_context(&mut self) -> Result<()> {\n")
  rs.add(
    "        if self.ctx != 0 { return Result::err(\"Context already created\"); }\n"
  )
  rs.add("        unsafe {\n")
  rs.add("            let mut err: *const c_char = std::ptr::null();\n")
  rs.add("            let ctx = " & p & "createContext(&mut err as *mut _);\n")
  rs.add("            if ctx == 0 {\n")
  rs.add("                let msg = if err.is_null() {\n")
  rs.add("                    String::from(\"createContext returned 0\")\n")
  rs.add("                } else {\n")
  rs.add(
    "                    let s = CStr::from_ptr(err).to_string_lossy().into_owned();\n"
  )
  rs.add("                    " & p & "freeBuffer(err as *mut c_void);\n")
  rs.add("                    s\n")
  rs.add("                };\n")
  rs.add("                return Result::err(msg);\n")
  rs.add("            }\n")
  rs.add("            self.ctx = ctx;\n")
  rs.add("            Result::ok(())\n")
  rs.add("        }\n")
  rs.add("    }\n\n")

  rs.add("    pub fn valid_context(&self) -> bool { self.ctx != 0 }\n")
  rs.add("    pub fn ctx(&self) -> u32 { self.ctx }\n\n")

  rs.add("    pub fn shutdown(&mut self) {\n")
  rs.add("        if self.ctx != 0 {\n")
  rs.add("            unsafe { " & p & "shutdown(self.ctx); }\n")
  rs.add("            // C broker has finished dispatching; safe to free closures.\n")
  rs.add("            drop_cbor_event_holders_for_ctx(self.ctx);\n")
  rs.add("            self.ctx = 0;\n")
  rs.add("        }\n")
  rs.add("    }\n\n")

  # Discovery helpers.
  rs.add(
    "    pub fn list_apis(&self) -> ::std::result::Result<serde_json::Value, String> {\n"
  )
  rs.add("        unsafe { fetch_descriptor(" & p & "listApis, \"listApis\") }\n")
  rs.add("    }\n\n")
  rs.add(
    "    pub fn get_schema(&self) -> ::std::result::Result<serde_json::Value, String> {\n"
  )
  rs.add("        unsafe { fetch_descriptor(" & p & "getSchema, \"getSchema\") }\n")
  rs.add("    }\n\n")

  # Internal call helper.
  rs.add(
    "    fn do_call(&self, api_name: &str, req_payload: &[u8]) -> ::std::result::Result<Vec<u8>, String> {\n"
  )
  rs.add(
    "        if self.ctx == 0 { return Err(\"Library context is not created\".into()); }\n"
  )
  rs.add("        unsafe {\n")
  rs.add(
    "            let cname = CString::new(api_name).map_err(|e| e.to_string())?;\n"
  )
  rs.add("            let in_buf: *const c_void = if req_payload.is_empty() {\n")
  rs.add("                std::ptr::null()\n")
  rs.add("            } else {\n")
  rs.add("                let p = " & p & "allocBuffer(req_payload.len() as i32);\n")
  rs.add(
    "                if p.is_null() { return Err(\"allocBuffer failed\".into()); }\n"
  )
  rs.add(
    "                std::ptr::copy_nonoverlapping(req_payload.as_ptr(), p as *mut u8, req_payload.len());\n"
  )
  rs.add("                p as *const c_void\n")
  rs.add("            };\n")
  rs.add("            let mut out_buf: *mut c_void = std::ptr::null_mut();\n")
  rs.add("            let mut out_len: i32 = 0;\n")
  rs.add("            let status = " & p & "call(\n")
  rs.add("                self.ctx,\n")
  rs.add("                cname.as_ptr(),\n")
  rs.add("                in_buf,\n")
  rs.add("                req_payload.len() as i32,\n")
  rs.add("                &mut out_buf as *mut _,\n")
  rs.add("                &mut out_len as *mut _,\n")
  rs.add("            );\n")
  rs.add("            let mut out: Vec<u8> = Vec::new();\n")
  rs.add("            if !out_buf.is_null() && out_len > 0 {\n")
  rs.add(
    "                let slice = std::slice::from_raw_parts(out_buf as *const u8, out_len as usize);\n"
  )
  rs.add("                out = slice.to_vec();\n")
  rs.add("                " & p & "freeBuffer(out_buf);\n")
  rs.add("            }\n")
  rs.add("            if status != 0 {\n")
  rs.add("                if status == -4 && !out.is_empty() {\n")
  rs.add(
    "                    return Err(String::from_utf8_lossy(&out).into_owned());\n"
  )
  rs.add("                }\n")
  rs.add("                return Err(format!(\"framework error: {}\", status));\n")
  rs.add("            }\n")
  rs.add("            Ok(out)\n")
  rs.add("        }\n")
  rs.add("    }\n\n")

  # Per-request methods. Factored into a reusable emitter so the main Lib impl
  # and each sub-interface impl share identical bodies (reduced-A).
  proc emitRustReqMethod(e: CborRequestEntry): string {.compileTime.} =
    if e.responseTypeName.len == 0:
      return ""
    if not isEmittablePayload(e.responseTypeName):
      return
        "    // TODO: '" & e.apiName & "' return type '" & e.responseTypeName &
        "' is not a registered object type.\n\n"
    for (n, t) in e.argFields:
      if not isRustMappable(t):
        return
          "    // TODO: '" & e.apiName &
          "' has parameters whose Nim types aren't yet mappable to Rust.\n\n"
    let methodName = e.apiName
    var sigParams = "&self"
    var argsStructDecl = ""
    var argsStructInit = ""
    if e.argFields.len > 0:
      argsStructDecl.add("        #[derive(Serialize)]\n")
      argsStructDecl.add("        struct __Args {\n")
      for (n, t) in e.argFields:
        sigParams.add(", " & n & ": " & nimTypeToRustHint(t))
        let lowered = t.toLowerAscii().strip()
        if lowered == "seq[byte]":
          argsStructDecl.add("            #[serde(with = \"serde_bytes\")]\n")
        elif lowered == "option[seq[byte]]":
          argsStructDecl.add(
            "            #[serde(with = \"::serde_bytes\", default, skip_serializing_if = \"Option::is_none\")]\n"
          )
        argsStructDecl.add("            " & n & ": " & nimTypeToRustHint(t) & ",\n")
        argsStructInit.add("            " & n & ",\n")
      argsStructDecl.add("        }\n")
    result.add(
      "    pub fn " & methodName & "(" & sigParams & ") -> Result<" & e.responseTypeName &
        "> {\n"
    )
    if e.argFields.len > 0:
      result.add(argsStructDecl)
      result.add("        let args = __Args {\n")
      result.add(argsStructInit)
      result.add("        };\n")
      result.add("        let mut buf: Vec<u8> = Vec::new();\n")
      result.add("        if let Err(e) = ciborium::into_writer(&args, &mut buf) {\n")
      result.add("            return Result::err(format!(\"cbor encode: {}\", e));\n")
      result.add("        }\n")
    else:
      result.add("        let buf: Vec<u8> = Vec::new();\n")
    result.add("        let raw = match self.do_call(\"" & e.apiName & "\", &buf) {\n")
    result.add("            Ok(v) => v,\n")
    result.add("            Err(e) => return Result::err(e),\n")
    result.add("        };\n")
    result.add("        if raw.is_empty() {\n")
    result.add("            return Result::err(\"empty response envelope\");\n")
    result.add("        }\n")
    result.add("        #[derive(Deserialize)]\n")
    result.add(
      "        struct __Env { #[serde(default)] ok: Option<" & e.responseTypeName &
        ">, #[serde(default)] err: Option<String> }\n"
    )
    result.add(
      "        let env: __Env = match ciborium::from_reader(raw.as_slice()) {\n"
    )
    result.add("            Ok(v) => v,\n")
    result.add(
      "            Err(e) => return Result::err(format!(\"cbor decode: {}\", e)),\n"
    )
    result.add("        };\n")
    result.add("        if let Some(msg) = env.err { return Result::err(msg); }\n")
    result.add("        match env.ok {\n")
    result.add("            Some(v) => Result::ok(v),\n")
    result.add("            None => Result::err(\"missing ok in envelope\"),\n")
    result.add("        }\n")
    result.add("    }\n\n")

  # reduced-A: a create-instance method returns the typed sub-wrapper. The wire
  # ok value is a bare u32 ctx; we construct `Sub { ctx }` from it (same module,
  # so the private field is accessible).
  proc emitRustInstanceMethod(e: CborRequestEntry): string {.compileTime.} =
    for (n, t) in e.argFields:
      if not isRustMappable(t):
        return "    // TODO: '" & e.apiName & "' has unmappable parameter types.\n\n"
    let sub = rustSubStructName(e.returnsInterface)
    var sigParams = "&self"
    var argsStructInit = ""
    var argsStructDecl = ""
    if e.argFields.len > 0:
      argsStructDecl.add("        #[derive(Serialize)]\n")
      argsStructDecl.add("        struct __Args {\n")
      for (n, t) in e.argFields:
        sigParams.add(", " & n & ": " & nimTypeToRustHint(t))
        argsStructDecl.add("            " & n & ": " & nimTypeToRustHint(t) & ",\n")
        argsStructInit.add("            " & n & ",\n")
      argsStructDecl.add("        }\n")
    result.add(
      "    pub fn " & e.apiName & "(" & sigParams & ") -> Result<" & sub & "> {\n"
    )
    if e.argFields.len > 0:
      result.add(argsStructDecl)
      result.add("        let args = __Args {\n")
      result.add(argsStructInit)
      result.add("        };\n")
      result.add("        let mut buf: Vec<u8> = Vec::new();\n")
      result.add("        if let Err(e) = ciborium::into_writer(&args, &mut buf) {\n")
      result.add("            return Result::err(format!(\"cbor encode: {}\", e));\n")
      result.add("        }\n")
    else:
      result.add("        let buf: Vec<u8> = Vec::new();\n")
    result.add("        let raw = match self.do_call(\"" & e.apiName & "\", &buf) {\n")
    result.add("            Ok(v) => v,\n")
    result.add("            Err(e) => return Result::err(e),\n")
    result.add("        };\n")
    result.add("        if raw.is_empty() {\n")
    result.add("            return Result::err(\"empty response envelope\");\n")
    result.add("        }\n")
    result.add("        #[derive(Deserialize)]\n")
    result.add(
      "        struct __Env { #[serde(default)] ok: Option<u32>, #[serde(default)] err: Option<String> }\n"
    )
    result.add(
      "        let env: __Env = match ciborium::from_reader(raw.as_slice()) {\n"
    )
    result.add("            Ok(v) => v,\n")
    result.add(
      "            Err(e) => return Result::err(format!(\"cbor decode: {}\", e)),\n"
    )
    result.add("        };\n")
    result.add("        if let Some(msg) = env.err { return Result::err(msg); }\n")
    result.add("        match env.ok {\n")
    result.add("            Some(v) => Result::ok(" & sub & " { ctx: v }),\n")
    result.add("            None => Result::err(\"missing ok in envelope\"),\n")
    result.add("        }\n")
    result.add("    }\n\n")

  rs.add("    // ---- Request methods ----\n\n")
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if not ownsReqMain(e):
      continue
    if e.returnsInterface.len > 0:
      rs.add(emitRustInstanceMethod(e))
    else:
      rs.add(emitRustReqMethod(e))

  # Per-event subscribe / unsubscribe.
  rs.add("    // ---- Event registration ----\n\n")
  for ev in eventEntries:
    if not ownsEvtMain(ev):
      continue
    if not isEmittablePayload(ev.typeName):
      rs.add(
        "    // TODO: event '" & ev.apiName & "' payload type '" & ev.typeName &
          "' is not a registered object type.\n\n"
      )
      continue
    let onName = "on_" & ev.apiName
    let offName = "off_" & ev.apiName
    # Build per-field type hints + per-field destructure args. The user
    # callback signature is `Fn(field1, field2, ...)` — parity with the
    # native-mode wrapper so the same client code drives either build.
    var hintParts: seq[string] = @[]
    var destructureArgs: seq[string] = @[]
    if isScalarPayload(ev.typeName):
      # Scalar payload: the decoded `v` IS the value — one bare arg.
      hintParts.add(primRustHint(resolveUnderlyingType(ev.typeName)))
      destructureArgs.add("v")
    else:
      for f in lookupTypeEntry(ev.typeName).fields:
        let hint = nimTypeToRustHint(f.nimType)
        hintParts.add(if hint.len > 0: hint else: "::serde_json::Value")
        destructureArgs.add("v." & f.name)
    let fnBound = hintParts.join(", ")
    rs.add(
      "    pub fn " & onName & "<F>(&self, callback: F) -> u64 where F: Fn(" & fnBound &
        ") + Send + Sync + 'static {\n"
    )
    rs.add("        if self.ctx == 0 { return 0; }\n")
    rs.add("        let wrapper: CborEventHandler = Arc::new(move |raw: &[u8]| {\n")
    rs.add(
      "            if let Ok(v) = ciborium::from_reader::<" & ev.typeName &
        ", _>(raw) {\n"
    )
    rs.add("                callback(" & destructureArgs.join(", ") & ");\n")
    rs.add("            }\n")
    rs.add("        });\n")
    rs.add(
      "        let raw: *mut c_void = Box::into_raw(Box::new(wrapper)) as *mut c_void;\n"
    )
    rs.add(
      "        let cname = match CString::new(\"" & ev.apiName &
        "\") { Ok(s) => s, Err(_) => { unsafe { drop(Box::from_raw(raw as *mut CborEventHandler)); } return 0 } };\n"
    )
    rs.add(
      "        let h = unsafe { " & p &
        "subscribe(self.ctx, cname.as_ptr(), cbor_trampoline, raw) };\n"
    )
    rs.add("        if h == 0 {\n")
    rs.add(
      "            unsafe { drop(Box::from_raw(raw as *mut CborEventHandler)); }\n"
    )
    rs.add("            return 0;\n")
    rs.add("        }\n")
    rs.add(
      "        cbor_event_holders().lock().unwrap().push(CborHolderEntry { ctx: self.ctx, ptr: raw });\n"
    )
    rs.add("        h\n")
    rs.add("    }\n\n")

    rs.add("    pub fn " & offName & "(&self, handle: u64) {\n")
    rs.add("        if self.ctx == 0 { return; }\n")
    rs.add(
      "        let cname = match CString::new(\"" & ev.apiName &
        "\") { Ok(s) => s, Err(_) => return };\n"
    )
    rs.add(
      "        unsafe { " & p & "unsubscribe(self.ctx, cname.as_ptr(), handle); }\n"
    )
    rs.add("    }\n\n")

  rs.add("}\n\n")

  rs.add("impl Default for " & className & " {\n")
  rs.add("    fn default() -> Self { Self::new() }\n")
  rs.add("}\n\n")

  rs.add("impl Drop for " & className & " {\n")
  rs.add("    fn drop(&mut self) { self.shutdown(); }\n")
  rs.add("}\n\n")

  # reduced-A: sub-interface wrapper structs. Each shares the single C ABI: its
  # methods call <lib>_call(ctx, ...) which the library routes by classCtx to
  # the same processing thread. Drop / close() calls <lib>_releaseInstance, after
  # which the Nim instance is reclaimed by the GC (no FFI-side ownership).
  for ifaceName in subInterfaceNames:
    let sub = rustSubStructName(ifaceName)
    rs.add(
      "// -------- " & sub & " — sub-instance wrapper of " & ifaceName & " --------\n"
    )
    rs.add("pub struct " & sub & " {\n")
    rs.add("    ctx: u32,\n")
    rs.add("}\n\n")
    rs.add("impl " & sub & " {\n")
    rs.add("    pub fn ctx(&self) -> u32 { self.ctx }\n")
    rs.add("    pub fn valid(&self) -> bool { self.ctx != 0 }\n\n")
    rs.add("    pub fn close(&mut self) {\n")
    rs.add("        if self.ctx != 0 {\n")
    rs.add("            unsafe { " & p & "releaseInstance(self.ctx); }\n")
    rs.add("            self.ctx = 0;\n")
    rs.add("        }\n")
    rs.add("    }\n\n")
    # Internal call helper (same shape as Lib::do_call, keyed by self.ctx).
    rs.add(
      "    fn do_call(&self, api_name: &str, req_payload: &[u8]) -> ::std::result::Result<Vec<u8>, String> {\n"
    )
    rs.add(
      "        if self.ctx == 0 { return Err(\"sub-instance is released\".into()); }\n"
    )
    rs.add("        unsafe {\n")
    rs.add(
      "            let cname = CString::new(api_name).map_err(|e| e.to_string())?;\n"
    )
    rs.add("            let in_buf: *const c_void = if req_payload.is_empty() {\n")
    rs.add("                std::ptr::null()\n")
    rs.add("            } else {\n")
    rs.add("                let p = " & p & "allocBuffer(req_payload.len() as i32);\n")
    rs.add(
      "                if p.is_null() { return Err(\"allocBuffer failed\".into()); }\n"
    )
    rs.add(
      "                std::ptr::copy_nonoverlapping(req_payload.as_ptr(), p as *mut u8, req_payload.len());\n"
    )
    rs.add("                p as *const c_void\n")
    rs.add("            };\n")
    rs.add("            let mut out_buf: *mut c_void = std::ptr::null_mut();\n")
    rs.add("            let mut out_len: i32 = 0;\n")
    rs.add("            let status = " & p & "call(\n")
    rs.add(
      "                self.ctx, cname.as_ptr(), in_buf, req_payload.len() as i32,\n"
    )
    rs.add("                &mut out_buf as *mut _, &mut out_len as *mut _,\n")
    rs.add("            );\n")
    rs.add("            let mut out: Vec<u8> = Vec::new();\n")
    rs.add("            if !out_buf.is_null() && out_len > 0 {\n")
    rs.add(
      "                let slice = std::slice::from_raw_parts(out_buf as *const u8, out_len as usize);\n"
    )
    rs.add("                out = slice.to_vec();\n")
    rs.add("                " & p & "freeBuffer(out_buf);\n")
    rs.add("            }\n")
    rs.add("            if status != 0 {\n")
    rs.add("                if status == -4 && !out.is_empty() {\n")
    rs.add(
      "                    return Err(String::from_utf8_lossy(&out).into_owned());\n"
    )
    rs.add("                }\n")
    rs.add("                return Err(format!(\"framework error: {}\", status));\n")
    rs.add("            }\n")
    rs.add("            Ok(out)\n")
    rs.add("        }\n")
    rs.add("    }\n\n")
    for e in requestEntries:
      if interfaceOwningRequestType(e.responseTypeName) == ifaceName:
        rs.add(emitRustReqMethod(e))
    # Sub-interface event methods (subscribe/unsubscribe keyed by self.ctx).
    for ev in eventEntries:
      if interfaceOwningEventType(ev.typeName) != ifaceName:
        continue
      if not isEmittablePayload(ev.typeName):
        rs.add(
          "    // TODO: event '" & ev.apiName & "' payload type '" & ev.typeName &
            "' is not a registered object type.\n\n"
        )
        continue
      let onName = "on_" & ev.apiName
      let offName = "off_" & ev.apiName
      var hintParts: seq[string] = @[]
      var destructureArgs: seq[string] = @[]
      if isScalarPayload(ev.typeName):
        hintParts.add(primRustHint(resolveUnderlyingType(ev.typeName)))
        destructureArgs.add("v")
      else:
        for f in lookupTypeEntry(ev.typeName).fields:
          let hint = nimTypeToRustHint(f.nimType)
          hintParts.add(if hint.len > 0: hint else: "::serde_json::Value")
          destructureArgs.add("v." & f.name)
      let fnBound = hintParts.join(", ")
      rs.add(
        "    pub fn " & onName & "<F>(&self, callback: F) -> u64 where F: Fn(" & fnBound &
          ") + Send + Sync + 'static {\n"
      )
      rs.add("        if self.ctx == 0 { return 0; }\n")
      rs.add("        let wrapper: CborEventHandler = Arc::new(move |raw: &[u8]| {\n")
      rs.add(
        "            if let Ok(v) = ciborium::from_reader::<" & ev.typeName &
          ", _>(raw) {\n"
      )
      rs.add("                callback(" & destructureArgs.join(", ") & ");\n")
      rs.add("            }\n")
      rs.add("        });\n")
      rs.add(
        "        let raw: *mut c_void = Box::into_raw(Box::new(wrapper)) as *mut c_void;\n"
      )
      rs.add(
        "        let cname = match CString::new(\"" & ev.apiName &
          "\") { Ok(s) => s, Err(_) => { unsafe { drop(Box::from_raw(raw as *mut CborEventHandler)); } return 0 } };\n"
      )
      rs.add(
        "        let h = unsafe { " & p &
          "subscribe(self.ctx, cname.as_ptr(), cbor_trampoline, raw) };\n"
      )
      rs.add("        if h == 0 {\n")
      rs.add(
        "            unsafe { drop(Box::from_raw(raw as *mut CborEventHandler)); }\n"
      )
      rs.add("            return 0;\n")
      rs.add("        }\n")
      rs.add(
        "        cbor_event_holders().lock().unwrap().push(CborHolderEntry { ctx: self.ctx, ptr: raw });\n"
      )
      rs.add("        h\n")
      rs.add("    }\n\n")
      rs.add("    pub fn " & offName & "(&self, handle: u64) {\n")
      rs.add("        if self.ctx == 0 { return; }\n")
      rs.add(
        "        let cname = match CString::new(\"" & ev.apiName &
          "\") { Ok(s) => s, Err(_) => return };\n"
      )
      rs.add(
        "        unsafe { " & p & "unsubscribe(self.ctx, cname.as_ptr(), handle); }\n"
      )
      rs.add("    }\n\n")
    rs.add("}\n\n")
    rs.add("impl Drop for " & sub & " {\n")
    rs.add("    fn drop(&mut self) { self.close(); }\n")
    rs.add("}\n\n")

  # Trampoline: each subscription's user_data points at a leaked
  # Box<Arc<closure>>. Clone the Arc cheaply (atomic refcount) so
  # in-flight callbacks survive a concurrent off / shutdown that drops
  # the holder.
  rs.add(
    "unsafe extern \"C\" fn cbor_trampoline(ctx: u32, name: *const c_char, buf: *const c_void, buf_len: i32, ud: *mut c_void) {\n"
  )
  rs.add("    let _ = ctx;\n")
  rs.add("    let _ = name;\n")
  rs.add("    if ud.is_null() || buf.is_null() || buf_len <= 0 { return; }\n")
  rs.add(
    "    let slice = std::slice::from_raw_parts(buf as *const u8, buf_len as usize);\n"
  )
  rs.add(
    "    let arc: CborEventHandler = unsafe { (*(ud as *const CborEventHandler)).clone() };\n"
  )
  rs.add("    arc(slice);\n")
  rs.add("}\n\n")

  # Discovery descriptor helper.
  rs.add("unsafe fn fetch_descriptor(\n")
  rs.add("    f: unsafe extern \"C\" fn(*mut *mut c_void, *mut i32) -> i32,\n")
  rs.add("    label: &str,\n")
  rs.add(") -> ::std::result::Result<serde_json::Value, String> {\n")
  rs.add("    let mut buf: *mut c_void = std::ptr::null_mut();\n")
  rs.add("    let mut len: i32 = 0;\n")
  rs.add("    let status = f(&mut buf as *mut _, &mut len as *mut _);\n")
  rs.add(
    "    if status != 0 { return Err(format!(\"{} framework error: {}\", label, status)); }\n"
  )
  rs.add("    if buf.is_null() || len <= 0 { return Ok(serde_json::Value::Null); }\n")
  rs.add(
    "    let slice = std::slice::from_raw_parts(buf as *const u8, len as usize);\n"
  )
  rs.add("    let v: serde_json::Value = match serde_json::from_slice(slice) {\n")
  rs.add("        Ok(v) => v,\n")
  rs.add("        Err(e) => {\n")
  rs.add("            " & p & "freeBuffer(buf);\n")
  rs.add("            return Err(format!(\"json decode {}: {}\", label, e));\n")
  rs.add("        }\n")
  rs.add("    };\n")
  rs.add("    " & p & "freeBuffer(buf);\n")
  rs.add("    Ok(v)\n")
  rs.add("}\n")

  try:
    writeFile(srcDir & "/lib.rs", rs)
  except IOError:
    error(
      "Failed to write generated CBOR Rust source '" & srcDir & "/lib.rs': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
