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

proc nimTypeToRustHint*(nimType: string): string {.compileTime.} =
  ## Recursive Nim → Rust type. Falls back to "" for types we can't yet map.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if isRustPrimitive(t):
    return primRustHint(t)
  if lower.startsWith("table[") and lower.endsWith("]"):
    # Table[K, V] -> HashMap<Krust, Vrust>, all scalar key types. Keys ride the
    # wire as CBOR text strings; non-String key fields get a `#[serde(with =
    # "cbor_strkey_map")]` adapter (see generateCborRustFile) that converts
    # text <-> typed key. string/char keys map to String and need no adapter.
    let (k, v) = parseTableParams(t)
    let kr = nimTypeToRustHint(k)
    let vr = nimTypeToRustHint(v)
    return
      if kr.len > 0 and vr.len > 0:
        "HashMap<" & kr & ", " & vr & ">"
      else:
        ""
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
      # Reference the emitted `pub type <name> = ...` alias BY NAME so
      # fields/params keep the meaningful type (`ContentTopic`, `Timestamp`)
      # instead of flattening to the underlying; "" when it doesn't map.
      if nimTypeToRustHint(resolveUnderlyingType(t)).len > 0:
        return t
      return ""
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

proc rustTableNeedsKeyConv*(nimType: string): bool {.compileTime.} =
  ## True when the field is a `Table[K, V]` whose Rust key type is not
  ## `String` — i.e. an int / enum / distinct-of-int key that must be
  ## converted to/from the text key on the wire via the `cbor_strkey_map`
  ## serde helper. (string / char keys map to `String` and need no helper.)
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if not (lower.startsWith("table[") and lower.endsWith("]")):
    return false
  let (k, _) = parseTableParams(t)
  let kr = nimTypeToRustHint(k)
  kr.len > 0 and kr != "String"

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
    asyncTimeoutMs: int = 30000,
    asyncQueueDepth: int = 64,
    signalEntries: seq[CborSignalEntry] = @[],
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
  # Async request surface (`<method>_async().await`) bridges the C response
  # callback to a runtime-agnostic futures-channel oneshot: the crate works
  # under tokio, smol, async-std, or futures::executor::block_on alike —
  # no async runtime is forced on consumers.
  cargo.add("futures-channel = \"0.3\"\n")
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
  rs.add("    fn " & p & "callAsync(\n")
  rs.add("        ctx: u32,\n")
  rs.add("        api_name: *const c_char,\n")
  rs.add("        in_buf: *const c_void,\n")
  rs.add("        in_len: i32,\n")
  rs.add("        req_id: u64,\n")
  rs.add("        timeout_ms: u32,\n")
  rs.add("        cb: ResponseCb,\n")
  rs.add("        user_data: *mut c_void,\n")
  rs.add("    ) -> i32;\n")
  rs.add(
    "    fn " & p & "listApis(out_buf: *mut *mut c_void, out_len: *mut i32) -> i32;\n"
  )
  rs.add(
    "    fn " & p & "getSchema(out_buf: *mut *mut c_void, out_len: *mut i32) -> i32;\n"
  )
  rs.add("}\n\n")

  rs.add(
    "pub type EventCb = unsafe extern \"C\" fn(ctx: u32, name: *const c_char, buf: *const c_void, buf_len: i32, ud: *mut c_void);\n"
  )
  rs.add(
    "pub type ResponseCb = unsafe extern \"C\" fn(ud: *mut c_void, req_id: u64, status: i32, resp_buf: *const c_void, resp_len: i32);\n\n"
  )

  # ---- Async request plumbing (runtime-agnostic oneshot bridge) --------
  rs.add("/// Max concurrent in-flight `_async` requests per context (full =>\n")
  rs.add("/// the async method returns `Err(AsyncError::Again)`).\n")
  rs.add("pub const ASYNC_QUEUE_DEPTH: u32 = " & $asyncQueueDepth & ";\n")
  rs.add("/// Library default dispatch timeout (ms) applied by `_async` methods.\n")
  rs.add("pub const DEFAULT_ASYNC_TIMEOUT_MS: u32 = " & $asyncTimeoutMs & ";\n\n")
  rs.add("/// Typed error surface of the `_async` methods, so callers can MATCH\n")
  rs.add("/// backpressure / timeout / shutdown instead of string-comparing. The\n")
  rs.add(
    "/// sync methods keep the wrapper `Result<T>` (cross-language parity surface).\n"
  )
  rs.add("#[derive(Debug, Clone, PartialEq, Eq)]\n")
  rs.add("pub enum AsyncError {\n")
  rs.add("    /// Async window full (EAGAIN, -6): NOT queued — back off and retry.\n")
  rs.add("    Again,\n")
  rs.add("    /// Provider exceeded the dispatch timeout (-12).\n")
  rs.add("    TimedOut,\n")
  rs.add("    /// Library shut down before the response was delivered (-11).\n")
  rs.add("    ShutDown,\n")
  rs.add("    /// Provider-level failure (the envelope `err`, or -4 unknown api).\n")
  rs.add("    Provider(String),\n")
  rs.add("    /// CBOR encode/decode failure in the wrapper.\n")
  rs.add("    Codec(String),\n")
  rs.add("    /// Any other framework status / enqueue rc.\n")
  rs.add("    Framework(i32),\n")
  rs.add("}\n\n")
  rs.add("impl AsyncError {\n")
  rs.add("    /// True when the call was rejected with EAGAIN — retry later.\n")
  rs.add("    pub fn is_again(&self) -> bool { matches!(self, AsyncError::Again) }\n")
  rs.add("}\n\n")
  rs.add("impl std::fmt::Display for AsyncError {\n")
  rs.add("    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {\n")
  rs.add("        match self {\n")
  rs.add("            AsyncError::Again => write!(f, \"EAGAIN: async window full\"),\n")
  rs.add("            AsyncError::TimedOut => write!(f, \"request timed out\"),\n")
  rs.add("            AsyncError::ShutDown => write!(f, \"library shut down\"),\n")
  rs.add("            AsyncError::Provider(m) => write!(f, \"{}\", m),\n")
  rs.add("            AsyncError::Codec(m) => write!(f, \"{}\", m),\n")
  rs.add(
    "            AsyncError::Framework(s) => write!(f, \"framework error: {}\", s),\n"
  )
  rs.add("        }\n")
  rs.add("    }\n")
  rs.add("}\n\n")
  rs.add("impl std::error::Error for AsyncError {}\n\n")
  rs.add(
    "type CborAsyncSlot = futures_channel::oneshot::Sender<::std::result::Result<Vec<u8>, AsyncError>>;\n\n"
  )
  rs.add(
    "/// C response trampoline: reconstruct the boxed oneshot sender (the opaque\n"
  )
  rs.add("/// userData), turn (status, respBuf) into Ok(bytes)/Err(AsyncError), and\n")
  rs.add(
    "/// fulfil it. Runs on the library's delivery thread; the caller's runtime\n/// (tokio, smol, block_on, ...) wakes the awaiting task.\n"
  )
  rs.add(
    "unsafe extern \"C\" fn cbor_response_trampoline(ud: *mut c_void, _req_id: u64, status: i32, resp_buf: *const c_void, resp_len: i32) {\n"
  )
  rs.add("    if ud.is_null() { return; }\n")
  rs.add(
    "    let sender: Box<CborAsyncSlot> = unsafe { Box::from_raw(ud as *mut CborAsyncSlot) };\n"
  )
  rs.add(
    "    let result: ::std::result::Result<Vec<u8>, AsyncError> = if status != 0 {\n"
  )
  rs.add(
    "        if status == " & $ApiStatusUnknownApi &
      " && !resp_buf.is_null() && resp_len > 0 {\n"
  )
  rs.add(
    "            let slice = unsafe { std::slice::from_raw_parts(resp_buf as *const u8, resp_len as usize) };\n"
  )
  rs.add(
    "            Err(AsyncError::Provider(String::from_utf8_lossy(slice).into_owned()))\n"
  )
  rs.add("        } else if status == " & $ApiStatusTimeout & " {\n")
  rs.add("            Err(AsyncError::TimedOut)\n")
  rs.add("        } else if status == " & $ApiStatusShutdown & " {\n")
  rs.add("            Err(AsyncError::ShutDown)\n")
  rs.add("        } else {\n")
  rs.add("            Err(AsyncError::Framework(status))\n")
  rs.add("        }\n")
  rs.add("    } else if resp_buf.is_null() || resp_len <= 0 {\n")
  rs.add("        Err(AsyncError::Codec(\"empty response envelope\".to_string()))\n")
  rs.add("    } else {\n")
  rs.add(
    "        let slice = unsafe { std::slice::from_raw_parts(resp_buf as *const u8, resp_len as usize) };\n"
  )
  rs.add("        Ok(slice.to_vec())\n")
  rs.add("    };\n")
  rs.add("    let _ = sender.send(result);\n")
  rs.add("}\n\n")

  # Shared `do_signal` body (used by the main Lib impl and each sub-impl that
  # owns a signal — both have a private `ctx: u32`, so a sub-interface signal
  # routes to that sub-instance's ctx). Slot-free one-way `_call`.
  proc emitRustDoSignal(p: string): string {.compileTime.} =
    result.add(
      "    fn do_signal(&self, api_name: &str, req_payload: &[u8]) -> ::std::result::Result<(), String> {\n"
    )
    result.add(
      "        if self.ctx == 0 { return Err(\"Library context is not created\".into()); }\n"
    )
    result.add("        unsafe {\n")
    result.add(
      "            let cname = CString::new(api_name).map_err(|e| e.to_string())?;\n"
    )
    result.add("            let in_buf: *const c_void = if req_payload.is_empty() {\n")
    result.add("                std::ptr::null()\n")
    result.add("            } else {\n")
    result.add(
      "                let p = " & p & "allocBuffer(req_payload.len() as i32);\n"
    )
    result.add(
      "                if p.is_null() { return Err(\"allocBuffer failed\".into()); }\n"
    )
    result.add(
      "                std::ptr::copy_nonoverlapping(req_payload.as_ptr(), p as *mut u8, req_payload.len());\n"
    )
    result.add("                p as *const c_void\n")
    result.add("            };\n")
    result.add("            let mut out_buf: *mut c_void = std::ptr::null_mut();\n")
    result.add("            let mut out_len: i32 = 0;\n")
    result.add("            let status = " & p & "call(\n")
    result.add(
      "                self.ctx, cname.as_ptr(), in_buf, req_payload.len() as i32,\n"
    )
    result.add("                &mut out_buf as *mut _, &mut out_len as *mut _,\n")
    result.add("            );\n")
    result.add(
      "            if !out_buf.is_null() && out_len > 0 { " & p &
        "freeBuffer(out_buf); }\n"
    )
    result.add("            match status {\n")
    result.add("                0 => Ok(()),\n")
    result.add(
      "                " & $ApiStatusAgain &
        " => Err(\"EAGAIN: signal queue full\".into()),\n"
    )
    result.add(
      "                " & $ApiStatusProviderErr &
        " => Err(\"no signal handler installed\".into()),\n"
    )
    result.add("                s => Err(format!(\"signal failed: {}\", s)),\n")
    result.add("            }\n")
    result.add("        }\n")
    result.add("    }\n\n")

  # Shared `do_call_async` body (used by the main Lib impl and each sub-impl —
  # both have a private `ctx: u32`). Encodes nothing; takes raw request bytes,
  # bridges the C response callback to a futures-channel oneshot (runtime-
  # agnostic), and returns the raw
  # response envelope bytes (the per-method async fn decodes them into T).
  proc emitDoCallAsync(p: string): string {.compileTime.} =
    result.add(
      "    async fn do_call_async(&self, api_name: &str, req_payload: &[u8], timeout_ms: u32) -> ::std::result::Result<Vec<u8>, AsyncError> {\n"
    )
    result.add(
      "        if self.ctx == 0 { return Err(AsyncError::Provider(\"Library context is not created\".into())); }\n"
    )
    result.add(
      "        let cname = CString::new(api_name).map_err(|e| AsyncError::Codec(e.to_string()))?;\n"
    )
    result.add("        let in_buf: *const c_void = if req_payload.is_empty() {\n")
    result.add("            std::ptr::null()\n")
    result.add("        } else {\n")
    result.add("            unsafe {\n")
    result.add(
      "                let bp = " & p & "allocBuffer(req_payload.len() as i32);\n"
    )
    result.add(
      "                if bp.is_null() { return Err(AsyncError::Codec(\"allocBuffer failed\".into())); }\n"
    )
    result.add(
      "                std::ptr::copy_nonoverlapping(req_payload.as_ptr(), bp as *mut u8, req_payload.len());\n"
    )
    result.add("                bp as *const c_void\n")
    result.add("            }\n")
    result.add("        };\n")
    result.add(
      "        let (tx, rx) = futures_channel::oneshot::channel::<::std::result::Result<Vec<u8>, AsyncError>>();\n"
    )
    result.add(
      "        let boxed: *mut c_void = Box::into_raw(Box::new(tx)) as *mut c_void;\n"
    )
    result.add("        let rc = unsafe {\n")
    result.add("            " & p & "callAsync(\n")
    result.add("                self.ctx,\n")
    result.add("                cname.as_ptr(),\n")
    result.add("                in_buf,\n")
    result.add("                req_payload.len() as i32,\n")
    result.add("                0,\n")
    result.add("                timeout_ms,\n")
    result.add("                cbor_response_trampoline,\n")
    result.add("                boxed,\n")
    result.add("            )\n")
    result.add("        };\n")
    result.add("        if rc != 0 {\n")
    result.add(
      "            // Not queued: the library freed in_buf (ABI) and the callback\n"
    )
    result.add("            // will NOT fire — reclaim the boxed sender ourselves.\n")
    result.add(
      "            unsafe { drop(Box::from_raw(boxed as *mut CborAsyncSlot)); }\n"
    )
    result.add(
      "            if rc == " & $ApiStatusAgain & " { return Err(AsyncError::Again); }\n"
    )
    result.add("            return Err(AsyncError::Framework(rc));\n")
    result.add("        }\n")
    result.add("        match rx.await {\n")
    result.add("            Ok(r) => r,\n")
    result.add(
      "            Err(_) => Err(AsyncError::Codec(\"response channel closed\".into())),\n"
    )
    result.add("        }\n")
    result.add("    }\n\n")

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
  # Full mapper (not just primRustHint) so a container payload (`seq[string]`
  # -> Vec<String>) is an emittable scalar payload, not only primitives.
  proc isScalarPayload(name: string): bool {.compileTime.} =
    name.len > 0 and isTypeRegistered(name) and
      lookupTypeEntry(name).kind in {atkAlias, atkDistinct} and
      nimTypeToRustHint(resolveUnderlyingType(name)).len > 0

  proc isEmittablePayload(name: string): bool {.compileTime.} =
    name in objectNames or isScalarPayload(name)

  if enumNames.len > 0 or aliasNames.len > 0 or objectNames.len > 0:
    rs.add("// -------- Generated payload types --------\n\n")

  # Enums.
  for name in enumNames:
    let entry = lookupTypeEntry(name)
    rs.add(
      "#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]\n"
    )
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
    # Display / FromStr over the ordinal so the enum can be a Table key via the
    # `cbor_strkey_map` serde helper (keys travel as text on the wire).
    rs.add("impl std::fmt::Display for " & name & " {\n")
    rs.add(
      "    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result { write!(f, \"{}\", *self as i32) }\n"
    )
    rs.add("}\n\n")
    rs.add("impl std::str::FromStr for " & name & " {\n")
    rs.add("    type Err = std::num::ParseIntError;\n")
    rs.add(
      "    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> { Ok(" & name &
        "::from(s.parse::<i32>()?)) }\n"
    )
    rs.add("}\n\n")

  # Distinct / alias. A bare-primitive response payload is unwrapped to the
  # simple type, so its synthetic `pub type Verb = bool;` alias is dead — skip it
  # (a field-used alias like `ContentTopic` is never a response name, so it stays).
  var responseNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len > 0 and e.responseTypeName notin responseNames:
      responseNames.add(e.responseTypeName)
  for name in aliasNames:
    if name in responseNames and effectiveResponsePayload(name) != name:
      continue
    let underlying = resolveUnderlyingType(name)
    let pyU = nimTypeToRustHint(underlying)
    if pyU.len == 0:
      rs.add(
        "// TODO: alias '" & name & "' resolves to '" & underlying &
          "' which has no Rust mapping\n\n"
      )
      continue
    rs.add("pub type " & name & " = " & pyU & ";\n\n")

  # Generic text-key <-> typed-key map adapter, emitted only when some object
  # field is a non-string-keyed Table. Table keys ride the wire as CBOR text
  # strings; this serde `with` helper converts them to/from the typed key
  # (int / enum / distinct) — string/char keys map to `String` and skip it.
  var needsStrKeyMap = false
  for name in objectNames:
    for f in lookupTypeEntry(name).fields:
      if rustTableNeedsKeyConv(f.nimType):
        needsStrKeyMap = true
  if needsStrKeyMap:
    rs.add("mod cbor_strkey_map {\n")
    rs.add("    use serde::de::Error as _;\n")
    rs.add("    use serde::ser::SerializeMap;\n")
    rs.add("    use serde::{Deserialize, Deserializer, Serialize, Serializer};\n")
    rs.add("    use std::collections::HashMap;\n")
    rs.add("    use std::fmt::Display;\n")
    rs.add("    use std::hash::Hash;\n")
    rs.add("    use std::str::FromStr;\n")
    rs.add(
      "    pub fn serialize<S, K, V>(m: &HashMap<K, V>, s: S) -> std::result::Result<S::Ok, S::Error>\n"
    )
    rs.add("    where S: Serializer, K: Display + Eq + Hash, V: Serialize {\n")
    rs.add("        let mut map = s.serialize_map(Some(m.len()))?;\n")
    rs.add("        for (k, v) in m { map.serialize_entry(&k.to_string(), v)?; }\n")
    rs.add("        map.end()\n")
    rs.add("    }\n")
    rs.add(
      "    pub fn deserialize<'de, D, K, V>(d: D) -> std::result::Result<HashMap<K, V>, D::Error>\n"
    )
    rs.add(
      "    where D: Deserializer<'de>, K: FromStr + Eq + Hash, <K as FromStr>::Err: Display, V: Deserialize<'de> {\n"
    )
    rs.add("        let sm = HashMap::<String, V>::deserialize(d)?;\n")
    rs.add("        let mut out = HashMap::with_capacity(sm.len());\n")
    rs.add(
      "        for (k, v) in sm { out.insert(k.parse::<K>().map_err(D::Error::custom)?, v); }\n"
    )
    rs.add("        Ok(out)\n")
    rs.add("    }\n")
    rs.add("}\n\n")

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
      elif rustTableNeedsKeyConv(f.nimType):
        rs.add("    #[serde(with = \"cbor_strkey_map\")]\n")
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
  rs.add(
    "                if status == " & $ApiStatusUnknownApi & " && !out.is_empty() {\n"
  )
  rs.add(
    "                    return Err(String::from_utf8_lossy(&out).into_owned());\n"
  )
  rs.add("                }\n")
  rs.add("                return Err(format!(\"framework error: {}\", status));\n")
  rs.add("            }\n")
  rs.add("            Ok(out)\n")
  rs.add("        }\n")
  rs.add("    }\n\n")

  # Slot-free one-way signal dispatch through `_call` (shared with sub-impls).
  rs.add(emitRustDoSignal(p))

  rs.add(emitDoCallAsync(p))

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
    # A synthetic proc-sugar payload surfaces its real type: the named alias
    # (`Result<RequestId>`), the bare primitive (`Result<bool>`), or the
    # synthetic name for an anonymous container (`Result<ConnectedPeers>`).
    let resp = effectiveResponsePayload(e.responseTypeName)
    let respRust =
      if isNimPrimitive(resp):
        primRustHint(resp)
      else:
        resp
    result.add(
      "    pub fn " & methodName & "(" & sigParams & ") -> Result<" & respRust & "> {\n"
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
      "        struct __Env { #[serde(default)] ok: Option<" & respRust &
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

    # ---- async sibling: `<method>_async().await` via oneshot bridge ----
    # Returns STD Result with the typed AsyncError (not the wrapper Result<T>):
    # composes with `?`/`.await?`, and EAGAIN/timeout/shutdown are matchable
    # variants instead of strings.
    # Per-call timeout parity with the C++/Python/Go wrappers: the ABI carries
    # a per-call `timeoutMs`, so expose it here as `Option<u32>` (ms). `None`
    # falls back to the library default — the idiomatic Rust analogue of the
    # defaulted C++ arg / Python `Optional[float]`.
    result.add(
      "    pub async fn " & methodName & "_async(" & sigParams &
        ", timeout_ms: Option<u32>) -> ::std::result::Result<" & respRust &
        ", AsyncError> {\n"
    )
    if e.argFields.len > 0:
      result.add(argsStructDecl)
      result.add("        let args = __Args {\n")
      result.add(argsStructInit)
      result.add("        };\n")
      result.add("        let mut buf: Vec<u8> = Vec::new();\n")
      result.add("        if let Err(e) = ciborium::into_writer(&args, &mut buf) {\n")
      result.add(
        "            return Err(AsyncError::Codec(format!(\"cbor encode: {}\", e)));\n"
      )
      result.add("        }\n")
    else:
      result.add("        let buf: Vec<u8> = Vec::new();\n")
    result.add(
      "        let timeout_ms = timeout_ms.unwrap_or(DEFAULT_ASYNC_TIMEOUT_MS);\n"
    )
    result.add(
      "        let raw = self.do_call_async(\"" & e.apiName &
        "\", &buf, timeout_ms).await?;\n"
    )
    result.add("        if raw.is_empty() {\n")
    result.add(
      "            return Err(AsyncError::Codec(\"empty response envelope\".into()));\n"
    )
    result.add("        }\n")
    result.add("        #[derive(Deserialize)]\n")
    result.add(
      "        struct __Env { #[serde(default)] ok: Option<" & respRust &
        ">, #[serde(default)] err: Option<String> }\n"
    )
    result.add(
      "        let env: __Env = match ciborium::from_reader(raw.as_slice()) {\n"
    )
    result.add("            Ok(v) => v,\n")
    result.add(
      "            Err(e) => return Err(AsyncError::Codec(format!(\"cbor decode: {}\", e))),\n"
    )
    result.add("        };\n")
    result.add(
      "        if let Some(msg) = env.err { return Err(AsyncError::Provider(msg)); }\n"
    )
    result.add("        match env.ok {\n")
    result.add("            Some(v) => Ok(v),\n")
    result.add(
      "            None => Err(AsyncError::Codec(\"missing ok in envelope\".into())),\n"
    )
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

  # Per-signal one-way methods: `pub fn <name>(&self, fields...) ->
  # Result<(), String>`. No async sibling — signals are one-way.
  proc emitRustSignalMethod(s: CborSignalEntry): string {.compileTime.} =
    if not isEmittablePayload(s.typeName):
      return
        "    // TODO: signal '" & s.apiName & "' payload '" & s.typeName &
        "' is not a registered type.\n\n"
    var fields: seq[ApiFieldDef]
    if s.typeName in objectNames:
      fields = lookupTypeEntry(s.typeName).fields
    else:
      fields = @[ApiFieldDef(name: "value", nimType: resolveUnderlyingType(s.typeName))]
    for f in fields:
      if not isRustMappable(f.nimType):
        return
          "    // TODO: signal '" & s.apiName &
          "' has fields whose Nim types aren't yet mappable to Rust.\n\n"
    var sigParams = "&self"
    for f in fields:
      sigParams.add(", " & f.name & ": " & nimTypeToRustHint(f.nimType))
    result.add("    #[allow(non_snake_case)]\n")
    result.add(
      "    pub fn " & s.apiName & "(" & sigParams &
        ") -> ::std::result::Result<(), String> {\n"
    )
    if fields.len == 0:
      result.add("        let buf: Vec<u8> = Vec::new();\n")
    elif s.typeName in objectNames:
      result.add("        #[derive(Serialize)]\n")
      result.add("        #[allow(non_snake_case)]\n")
      result.add("        struct __Sig {\n")
      for f in fields:
        let lowered = f.nimType.toLowerAscii().strip()
        if lowered == "seq[byte]":
          result.add("            #[serde(with = \"serde_bytes\")]\n")
        elif lowered == "option[seq[byte]]":
          result.add(
            "            #[serde(with = \"::serde_bytes\", default, skip_serializing_if = \"Option::is_none\")]\n"
          )
        result.add(
          "            " & f.name & ": " & nimTypeToRustHint(f.nimType) & ",\n"
        )
      result.add("        }\n")
      result.add("        let sig = __Sig {\n")
      for f in fields:
        result.add("            " & f.name & ",\n")
      result.add("        };\n")
      result.add("        let mut buf: Vec<u8> = Vec::new();\n")
      result.add("        if let Err(e) = ciborium::into_writer(&sig, &mut buf) {\n")
      result.add("            return Err(format!(\"cbor encode: {}\", e));\n")
      result.add("        }\n")
    else:
      result.add("        let mut buf: Vec<u8> = Vec::new();\n")
      result.add("        if let Err(e) = ciborium::into_writer(&value, &mut buf) {\n")
      result.add("            return Err(format!(\"cbor encode: {}\", e));\n")
      result.add("        }\n")
    result.add("        self.do_signal(\"" & s.apiName & "\", &buf)\n")
    result.add("    }\n\n")

  var mainSigs: seq[CborSignalEntry] = @[]
  for s in signalEntries:
    if ownsSigMain(s):
      mainSigs.add(s)
  if mainSigs.len > 0:
    rs.add("    // ---- Signal methods ----\n\n")
    for s in mainSigs:
      rs.add(emitRustSignalMethod(s))

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
    rs.add(
      "                if status == " & $ApiStatusUnknownApi & " && !out.is_empty() {\n"
    )
    rs.add(
      "                    return Err(String::from_utf8_lossy(&out).into_owned());\n"
    )
    rs.add("                }\n")
    rs.add("                return Err(format!(\"framework error: {}\", status));\n")
    rs.add("            }\n")
    rs.add("            Ok(out)\n")
    rs.add("        }\n")
    rs.add("    }\n\n")
    rs.add(emitDoCallAsync(p))
    # Sub-interface one-way signals (routed by self.ctx — this instance). Emit
    # do_signal only when this sub-interface owns at least one signal.
    var ifaceSigs: seq[CborSignalEntry] = @[]
    for s in signalEntries:
      if interfaceOwningSignalType(s.typeName) == ifaceName:
        ifaceSigs.add(s)
    if ifaceSigs.len > 0:
      rs.add(emitRustDoSignal(p))
      for s in ifaceSigs:
        rs.add(emitRustSignalMethod(s))
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
