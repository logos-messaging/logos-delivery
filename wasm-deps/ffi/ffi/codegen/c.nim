## C99 binding generator. `abi = cbor` (default) emits three CBOR headers;
## `abi = c` emits one header whose structs are the C ABI directly. Lacking
## generics, each distinct `seq[T]`/`Option[T]` is monomorphised per type.

import std/[os, strutils, tables, sets, options]
import ./meta, ./string_helpers, ./c_cpp_common, ./types_ir, ./consts

## Fixed 64-bit wire type for any Nim `ptr T`/`pointer` (mirrors CppPtrType).
const CPtrType* = "uint64_t"

const
  HeaderPreludeTpl = staticRead("templates/c/header_prelude.h.tpl")
  CborHelpersTpl = staticRead("templates/c/cbor_helpers.h.tpl")
  CMakeListsTpl = staticRead("templates/c/CMakeLists.txt.tpl")

  # Shared header names; must match the include guards baked into the templates.
  PreludeHeaderName* = "nim_ffi_prelude.h"
  CborHeaderName* = "nim_ffi_cbor.h"

const scalarCInfoTable: array[ScalarKind, tuple[cType, suffix: string]] = [
  skBool: ("bool", "bool"),
  skI8: ("int8_t", "i8"),
  skI16: ("int16_t", "i16"),
  skI32: ("int32_t", "i32"),
  skI64: ("int64_t", "i64"),
  skU8: ("uint8_t", "u8"),
  skU16: ("uint16_t", "u16"),
  skU32: ("uint32_t", "u32"),
  skU64: ("uint64_t", "u64"),
  skF32: ("float", "f32"),
  skF64: ("double", "f64"),
]

func leafSuffix(cType: string): string =
  ## Leaf codec suffix for `cType`; "" for composites.
  for s in ScalarKind:
    if scalarCInfoTable[s].cType == cType:
      return scalarCInfoTable[s].suffix
  return
    case cType
    of "NimFfiStr": "str"
    of "NimFfiBytes": "bytes"
    else: ""

func cToken(cType: string): string =
  ## PascalCase token for monomorphised names.
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return capitalizeFirstLetter(suffix)
  return cType

type CTypeReg = object
  libName: string ## snake_case symbol prefix
  libType: string ## PascalCase container-name prefix
  typeTable: Table[string, FFITypeMeta]
  emitted: HashSet[string]
  owns: Table[string, bool] ## C type name → owns-heap-memory
  decls: seq[string]
  codecs: seq[string]

func encFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_enc_" & suffix
  return reg.libName & "_enc_" & cType

func decFn(reg: CTypeReg, cType: string): string =
  let suffix = leafSuffix(cType)
  if suffix.len > 0:
    return "nimffi_dec_" & suffix
  return reg.libName & "_dec_" & cType

func freeFn(reg: CTypeReg, cType: string): string =
  ## Free-function name for `cType`, or "" when it owns no heap memory.
  return
    case cType
    of "NimFfiStr":
      "nimffi_free_str"
    of "NimFfiBytes":
      "nimffi_free_bytes"
    else:
      if leafSuffix(cType).len > 0:
        ""
      elif reg.owns.getOrDefault(cType, false):
        reg.libName & "_free_" & cType
      else:
        ""

proc emitSeqType(reg: var CTypeReg, name, elemC: string) =
  let eEnc = encFn(reg, elemC)
  let eDec = decFn(reg, elemC)
  let eFree = freeFn(reg, elemC)
  reg.decls.add(
    "typedef struct {\n    " & elemC & "* data;\n    size_t len;\n} " & name & ";"
  )
  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & name & "(")
  body.add("        CborEncoder* e, const " & name & "* v) {")
  body.add("    CborEncoder arr;")
  body.add("    CborError err = cbor_encoder_create_array(e, &arr, v->len);")
  body.add("    if (err) return err;")
  body.add("    for (size_t i = 0; i < v->len; i++) {")
  body.add("        err = " & eEnc & "(&arr, &v->data[i]);")
  body.add("        if (err) return err;")
  body.add("    }")
  body.add("    return cbor_encoder_close_container(e, &arr);")
  body.add("}")
  body.add("static inline CborError " & reg.libName & "_dec_" & name & "(")
  body.add("        CborValue* it, " & name & "* out) {")
  body.add("    if (!cbor_value_is_array(it)) return CborErrorImproperValue;")
  body.add("    size_t len = 0;")
  body.add("    CborError err = cbor_value_get_array_length(it, &len);")
  body.add("    if (err) return err;")
  body.add(
    "    out->data = (" & elemC & "*)calloc(len ? len : 1, sizeof(" & elemC & "));"
  )
  body.add("    if (!out->data) return CborErrorOutOfMemory;")
  body.add("    out->len = len;")
  body.add("    CborValue inner;")
  body.add("    err = cbor_value_enter_container(it, &inner);")
  body.add("    if (err) return err;")
  body.add("    for (size_t i = 0; i < len; i++) {")
  body.add("        err = " & eDec & "(&inner, &out->data[i]);")
  body.add("        if (err) return err;")
  body.add("    }")
  body.add("    return cbor_value_leave_container(it, &inner);")
  body.add("}")
  body.add(
    "static inline void " & reg.libName & "_free_" & name & "(" & name & "* v) {"
  )
  body.add("    if (!v || !v->data) return;")
  if eFree.len > 0:
    body.add("    for (size_t i = 0; i < v->len; i++) " & eFree & "(&v->data[i]);")
  body.add("    free(v->data);")
  body.add("    v->data = NULL;")
  body.add("    v->len = 0;")
  body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[name] = true

proc emitOptType(reg: var CTypeReg, name, elemC: string, elemOwns: bool) =
  let eEnc = encFn(reg, elemC)
  let eDec = decFn(reg, elemC)
  let eFree = freeFn(reg, elemC)
  reg.decls.add(
    "typedef struct {\n    bool has_value;\n    " & elemC & " value;\n} " & name & ";"
  )
  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & name & "(")
  body.add("        CborEncoder* e, const " & name & "* v) {")
  body.add("    if (!v->has_value) return cbor_encode_null(e);")
  body.add("    return " & eEnc & "(e, &v->value);")
  body.add("}")
  body.add("static inline CborError " & reg.libName & "_dec_" & name & "(")
  body.add("        CborValue* it, " & name & "* out) {")
  body.add("    if (cbor_value_is_null(it)) {")
  body.add("        out->has_value = false;")
  body.add("        memset(&out->value, 0, sizeof(out->value));")
  body.add("        return cbor_value_advance(it);")
  body.add("    }")
  body.add("    out->has_value = true;")
  body.add("    return " & eDec & "(it, &out->value);")
  body.add("}")
  if elemOwns and eFree.len > 0:
    body.add(
      "static inline void " & reg.libName & "_free_" & name & "(" & name & "* v) {"
    )
    body.add("    if (!v || !v->has_value) return;")
    body.add("    " & eFree & "(&v->value);")
    body.add("    v->has_value = false;")
    body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[name] = elemOwns

proc ensureCType(reg: var CTypeReg, nimType: string): tuple[cType: string, owns: bool]

func enumConstName*(typeName, valueName: string): string =
  ## C/CDDL-safe constant name for an enum value, e.g. ("Color", "cRed") → COLOR_C_RED.
  return identToUpperSnake(typeName) & "_" & identToUpperSnake(valueName)

proc emitEnumType(reg: var CTypeReg, t: FFITypeMeta) =
  ## A `{.ffi.}` enum becomes a C enum whose codec maps to the CBOR text form
  ## (the value's Nim symbol name, or its associated string) that
  ## cbor_serialization writes.
  var members: seq[string] = @[]
  for v in t.enumValues:
    members.add("    " & enumConstName(t.name, v.name) & " = " & $v.ord & ",")
  members[^1].removeSuffix(',')
  reg.decls.add("typedef enum {\n" & members.join("\n") & "\n} " & t.name & ";")

  var longest = 0
  for v in t.enumValues:
    longest = max(longest, v.wire.len)

  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & t.name & "(")
  body.add("        CborEncoder* e, const " & t.name & "* v) {")
  body.add("    switch (*v) {")
  for v in t.enumValues:
    body.add(
      "    case " & enumConstName(t.name, v.name) &
        ": return cbor_encode_text_stringz(e, \"" & v.wire & "\");"
    )
  body.add("    }")
  body.add("    return CborErrorImproperValue;")
  body.add("}")

  body.add("static inline CborError " & reg.libName & "_dec_" & t.name & "(")
  body.add("        CborValue* it, " & t.name & "* out) {")
  body.add("    if (!cbor_value_is_text_string(it)) return CborErrorImproperValue;")
  body.add("    size_t len = 0;")
  body.add("    CborError err = cbor_value_get_string_length(it, &len);")
  body.add("    if (err) return err;")
  body.add("    char buf[" & $(longest + 1) & "];")
  body.add("    if (len >= sizeof(buf)) return CborErrorImproperValue;")
  body.add("    size_t copied = sizeof(buf);")
  body.add("    err = cbor_value_copy_text_string(it, buf, &copied, NULL);")
  body.add("    if (err) return err;")
  body.add("    buf[len] = '\\0';")
  for v in t.enumValues:
    body.add(
      "    if (strcmp(buf, \"" & v.wire & "\") == 0) { *out = " &
        enumConstName(t.name, v.name) & "; return cbor_value_advance(it); }"
    )
  body.add("    return CborErrorImproperValue;")
  body.add("}")

  reg.codecs.add(body.join("\n"))
  reg.owns[t.name] = false

proc emitStructType(reg: var CTypeReg, t: FFITypeMeta) =
  var fieldDecls: seq[string] = @[]
  var members: seq[tuple[name, cType: string, owns: bool]] = @[]
  for f in t.fields:
    let (cType, owns) = ensureCType(reg, f.typeName)
    fieldDecls.add("    " & cType & " " & f.name & ";")
    members.add((f.name, cType, owns))
  if members.len == 0:
    fieldDecls.add("    char _nimffi_empty; /* C forbids empty structs */")
  reg.decls.add("typedef struct {\n" & fieldDecls.join("\n") & "\n} " & t.name & ";")

  var body: seq[string] = @[]
  body.add("static inline CborError " & reg.libName & "_enc_" & t.name & "(")
  body.add("        CborEncoder* e, const " & t.name & "* v) {")
  if members.len == 0:
    body.add("    (void)v;")
  body.add("    CborEncoder m;")
  body.add("    CborError err = cbor_encoder_create_map(e, &m, " & $members.len & ");")
  body.add("    if (err) return err;")
  for mem in members:
    body.add("    err = cbor_encode_text_stringz(&m, \"" & mem.name & "\");")
    body.add("    if (err) return err;")
    body.add("    err = " & encFn(reg, mem.cType) & "(&m, &v->" & mem.name & ");")
    body.add("    if (err) return err;")
  body.add("    return cbor_encoder_close_container(e, &m);")
  body.add("}")

  body.add("static inline CborError " & reg.libName & "_dec_" & t.name & "(")
  body.add("        CborValue* it, " & t.name & "* out) {")
  body.add("    if (!cbor_value_is_map(it)) return CborErrorImproperValue;")
  if members.len == 0:
    body.add("    (void)out;")
    body.add("    return cbor_value_advance(it);")
  else:
    body.add("    CborValue field;")
    body.add("    CborError err;")
    for mem in members:
      body.add("    err = cbor_value_map_find_value(it, \"" & mem.name & "\", &field);")
      body.add("    if (err) return err;")
      body.add("    if (!cbor_value_is_valid(&field)) return CborErrorImproperValue;")
      body.add(
        "    err = " & decFn(reg, mem.cType) & "(&field, &out->" & mem.name & ");"
      )
      body.add("    if (err) return err;")
    body.add("    return cbor_value_advance(it);")
  body.add("}")

  var owns = false
  for mem in members:
    if mem.owns:
      owns = true
  if owns:
    body.add(
      "static inline void " & reg.libName & "_free_" & t.name & "(" & t.name & "* v) {"
    )
    body.add("    if (!v) return;")
    for mem in members:
      let ff = freeFn(reg, mem.cType)
      if mem.owns and ff.len > 0:
        body.add("    " & ff & "(&v->" & mem.name & ");")
    body.add("}")
  reg.codecs.add(body.join("\n"))
  reg.owns[t.name] = owns

proc ensureCType(reg: var CTypeReg, t: FFIType): tuple[cType: string, owns: bool] =
  ## Lowers an `FFIType` to a C type, monomorphising each `seq[T]`/`Option[T]`
  ## on first sight. `owns` marks a type the caller must free.
  case t.kind
  of ftPtr:
    return (CPtrType, false)
  of ftScalar:
    return (scalarCInfoTable[t.scalar].cType, false)
  of ftStr:
    return ("NimFfiStr", true)
  of ftBytes:
    return ("NimFfiBytes", true)
  of ftSeq:
    let (elemC, _) = ensureCType(reg, t.elem)
    let name = reg.libType & "Seq_" & cToken(elemC)
    if name notin reg.emitted:
      reg.emitted.incl(name)
      emitSeqType(reg, name, elemC)
    return (name, true)
  of ftOpt:
    let (elemC, elemOwns) = ensureCType(reg, t.elem)
    let name = reg.libType & "Opt_" & cToken(elemC)
    if name notin reg.emitted:
      reg.emitted.incl(name)
      emitOptType(reg, name, elemC, elemOwns)
    return (name, reg.owns.getOrDefault(name, false))
  of ftStruct:
    let name = t.name
    if name notin reg.emitted:
      reg.emitted.incl(name)
      if name in reg.typeTable:
        let meta = reg.typeTable[name]
        if meta.isEnum():
          emitEnumType(reg, meta)
        else:
          emitStructType(reg, meta)
      else:
        reg.decls.add("/* unknown type referenced: " & name & " */")
    return (name, reg.owns.getOrDefault(name, false))

proc ensureCType(reg: var CTypeReg, nimType: string): tuple[cType: string, owns: bool] =
  return ensureCType(reg, parseFFIType(nimType))

proc reqTypeMeta(p: FFIProcMeta): FFITypeMeta =
  ## Synthesises the per-proc Req struct; pointer/handle params ride as uint64.
  var fields: seq[FFIFieldMeta] = @[]
  for ep in p.extraParams:
    let typeName = if ep.ridesAsPtr(): "pointer" else: ep.typeName
    fields.add(FFIFieldMeta(name: ep.name, typeName: typeName))
  return FFITypeMeta(name: reqStructName(p), fields: fields)

func paramByValue(reg: CTypeReg, nimType: string, ridesAsPtr: bool): bool =
  ## Scalars/pointers/string views and enums pass by value; aggregates by const pointer.
  if ridesAsPtr:
    return true
  let t = parseFFIType(nimType)
  if t.kind == ftStruct and reg.typeTable.getOrDefault(t.name).isEnum():
    return true
  return t.kind in {ftScalar, ftStr, ftPtr}

proc cReturnType(reg: var CTypeReg, p: FFIProcMeta): string =
  if p.returnRidesAsPtr():
    return CPtrType
  return ensureCType(reg, p.returnTypeName).cType

proc buildReqParams(
    reg: var CTypeReg, eps: seq[FFIParamMeta]
): tuple[params, assigns: seq[string]] =
  var params: seq[string] = @[]
  var assigns: seq[string] = @[]
  for ep in eps:
    let rides = ep.ridesAsPtr()
    let cType =
      if rides:
        CPtrType
      else:
        ensureCType(reg, ep.typeName).cType
    if paramByValue(reg, ep.typeName, rides):
      params.add(cType & " " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = " & ep.name & ";")
    else:
      params.add("const " & cType & "* " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = *" & ep.name & ";")
  return (params, assigns)

proc evNames(
    libType, libName: string, ev: FFIEventMeta
): tuple[fnType, boxType, tramp, regName: string] =
  let pascal = capitalizeFirstLetter(ev.nimProcName)
  let snake = camelToSnakeCase(ev.nimProcName)
  return (
    libType & pascal & "Fn",
    libType & pascal & "Box",
    libName & "_" & snake & "_trampoline",
    libName & "_ctx_add_" & snake & "_listener",
  )

proc emitEventMachinery(
    lines: var seq[string],
    reg: CTypeReg,
    libType, libName: string,
    events: seq[FFIEventMeta],
) =
  if events.len == 0:
    return
  lines.add("/* Event listener machinery */")
  for ev in events:
    let n = evNames(libType, libName, ev)
    let payC = ev.payloadTypeName
    let payFree = freeFn(reg, payC)
    lines.add(
      "typedef void (*" & n.fnType & ")(const " & payC & "* evt, void* user_data);"
    )
    lines.add(
      "typedef struct { " & n.fnType & " fn; void* user_data; } " & n.boxType & ";"
    )
    lines.add(
      "static void " & n.tramp & "(int ret, const char* msg, size_t len, void* ud) {"
    )
    lines.add("    if (!ud || ret != 0 || !msg || len == 0) return;")
    lines.add("    " & n.boxType & "* box = (" & n.boxType & "*)ud;")
    lines.add("    if (!box->fn) return;")
    lines.add("    CborParser parser;")
    lines.add("    CborValue it;")
    lines.add(
      "    if (cbor_parser_init((const uint8_t*)msg, len, 0, &parser, &it) != CborNoError) return;"
    )
    lines.add("    if (!cbor_value_is_map(&it)) return;")
    lines.add("    CborValue payloadField;")
    lines.add(
      "    if (cbor_value_map_find_value(&it, \"payload\", &payloadField) != CborNoError) return;"
    )
    lines.add("    " & payC & " payload;")
    lines.add("    memset(&payload, 0, sizeof(payload));")
    lines.add(
      "    if (" & decFn(reg, payC) & "(&payloadField, &payload) != CborNoError) return;"
    )
    lines.add("    box->fn(&payload, box->user_data);")
    if payFree.len > 0:
      lines.add("    " & payFree & "(&payload);")
    lines.add("}")
    lines.add("")

proc emitContextStruct(
    lines: var seq[string], ctxType: string, events: seq[FFIEventMeta]
) =
  lines.add("/* ============================================================ */")
  lines.add("/* High-level context wrapper                                   */")
  lines.add("/* ============================================================ */")
  if events.len > 0:
    lines.add("typedef struct {")
    lines.add("    uint64_t id;")
    lines.add("    void* box;")
    lines.add("} " & ctxType & "Listener;")
    lines.add("")
  lines.add("typedef struct {")
  lines.add("    void* ptr;")
  if events.len > 0:
    lines.add("    " & ctxType & "Listener* listeners;")
    lines.add("    size_t listeners_len;")
    lines.add("    size_t listeners_cap;")
  lines.add("} " & ctxType & ";")
  lines.add("")

proc emitCallBox(lines: var seq[string], fnType, boxType: string) =
  lines.add("typedef struct { " & fnType & " fn; void* user_data; } " & boxType & ";")

proc emitReplyTrampolineHead(lines: var seq[string], tramp, boxType, fallback: string) =
  ## Opens a reply trampoline: recover the box, fail if no callback, deliver a
  ## non-zero `ret` as an error (msg/len isn't NUL-terminated, so copy it).
  lines.add(
    "static void " & tramp & "(int ret, const char* msg, size_t len, void* ud) {"
  )
  lines.add("    " & boxType & "* box = (" & boxType & "*)ud;")
  lines.add(
    "    /* Non-terminal progress ping: keep the box for the terminal reply. */"
  )
  lines.add("    if (ret == NIMFFI_RET_STALE_WARN) return;")
  lines.add("    if (!box->fn) {")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    if (ret != 0) {")
  lines.add("        char* em = nimffi_dup_cstr_n(msg ? msg : \"\", msg ? len : 0);")
  lines.add(
    "        box->fn(ret, NULL, em ? em : \"" & fallback & "\", box->user_data);"
  )
  lines.add("        free(em);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")

proc emitConstructors(
    lines: var seq[string],
    reg: var CTypeReg,
    ctxType, libType, libName: string,
    ctors: seq[FFIProcMeta],
) =
  if ctors.len == 0:
    return
  let fnType = libType & "CreateFn"
  let boxType = libType & "CreateBox"
  let tramp = libName & "_create_trampoline"
  lines.add(
    "typedef void (*" & fnType & ")(int err_code, " & ctxType &
      "* ctx, const char* err_msg, void* user_data);"
  )
  emitCallBox(lines, fnType, boxType)
  emitReplyTrampolineHead(lines, tramp, boxType, "FFI create failed")
  lines.add("    char* err = NULL;")
  lines.add("    NimFfiStr addr;")
  lines.add("    memset(&addr, 0, sizeof(addr));")
  lines.add(
    "    if (nimffi_decode_from_buf(" & libName &
      "_decv_Str, (const uint8_t*)msg, len, &addr, &err) != 0) {"
  )
  lines.add("        box->fn(-1, NULL, err ? err : \"decode failed\", box->user_data);")
  lines.add("        free(err);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    char* endp = NULL;")
  lines.add(
    "    unsigned long long a = addr.data ? strtoull(addr.data, &endp, 10) : 0;"
  )
  lines.add("    bool ok = addr.data && addr.len > 0 && endp && *endp == '\\0';")
  lines.add("    nimffi_free_str(&addr);")
  lines.add("    if (!ok) {")
  lines.add(
    "        box->fn(-1, NULL, \"FFI create returned non-numeric address\", box->user_data);"
  )
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add(
    "    " & ctxType & "* ctx = (" & ctxType & "*)calloc(1, sizeof(" & ctxType & "));"
  )
  lines.add("    if (!ctx) {")
  lines.add("        box->fn(-1, NULL, \"out of memory\", box->user_data);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    ctx->ptr = (void*)(uintptr_t)a;")
  lines.add("    box->fn(NIMFFI_RET_OK, ctx, NULL, box->user_data);")
  lines.add("    free(box);")
  lines.add("}")
  lines.add("")
  for ctor in ctors:
    let reqName = reqStructName(ctor)
    let (params, assigns) = buildReqParams(reg, ctor.extraParams)
    let head = "static inline int " & libName & "_ctx_create("
    let sig =
      if params.len > 0:
        head & params.join(", ") & ", " & fnType & " on_created, void* user_data) {"
      else:
        head & fnType & " on_created, void* user_data) {"
    lines.add(renderBlockDocComment(ctor.doc))
    lines.add(sig)
    lines.add("    " & reqName & " ffi_req;")
    lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
    for a in assigns:
      lines.add(a)
    lines.add("    uint8_t* req_buf = NULL;")
    lines.add("    size_t req_len = 0;")
    lines.add("    char* err = NULL;")
    lines.add(
      "    if (nimffi_encode_to_buf(" & libName & "_encv_" & cToken(reqName) &
        ", &ffi_req, &req_buf, &req_len, &err) != 0) {"
    )
    lines.add(
      "        if (on_created) on_created(-1, NULL, err ? err : \"encode failed\", user_data);"
    )
    lines.add("        free(err);")
    lines.add("        return -1;")
    lines.add("    }")
    lines.add(
      "    " & boxType & "* box = (" & boxType & "*)malloc(sizeof(" & boxType & "));"
    )
    lines.add("    if (!box) {")
    lines.add("        free(req_buf);")
    lines.add(
      "        if (on_created) on_created(-1, NULL, \"out of memory\", user_data);"
    )
    lines.add("        return -1;")
    lines.add("    }")
    lines.add("    box->fn = on_created;")
    lines.add("    box->user_data = user_data;")
    lines.add("    (void)" & ctor.procName & "(req_buf, req_len, " & tramp & ", box);")
    lines.add("    free(req_buf);")
    lines.add("    return 0;")
    lines.add("}")
    lines.add("")

proc emitDestructor(
    lines: var seq[string],
    ctxType, libName: string,
    dtor: Option[FFIProcMeta],
    events: seq[FFIEventMeta],
) =
  if dtor.isSome():
    lines.add(renderBlockDocComment(dtor.get().doc))
  lines.add("static inline int " & libName & "_ctx_destroy(" & ctxType & "* ctx) {")
  lines.add("    if (!ctx) return NIMFFI_RET_OK;")
  lines.add("    int rc = NIMFFI_RET_OK;")
  if dtor.isSome():
    lines.add(
      "    if (ctx->ptr) { rc = " & dtor.get().procName &
        "(ctx->ptr); ctx->ptr = NULL; }"
    )
  if events.len > 0:
    # A failed teardown leaves the worker threads live (ffi_context.nim:
    # stopAndJoinThreads), and they still hold each box as callback user_data.
    # Leaking a box beats handing a running event thread a dangling pointer.
    lines.add("    if (rc == NIMFFI_RET_OK) {")
    lines.add(
      "        for (size_t i = 0; i < ctx->listeners_len; i++) free(ctx->listeners[i].box);"
    )
    lines.add("    }")
    lines.add("    free(ctx->listeners);")
  lines.add("    free(ctx);")
  lines.add("    return rc;")
  lines.add("}")
  lines.add("")

proc emitListenerApi(
    lines: var seq[string], ctxType, libType, libName: string, events: seq[FFIEventMeta]
) =
  if events.len == 0:
    return
  for ev in events:
    let n = evNames(libType, libName, ev)
    lines.add(renderBlockDocComment(ev.doc))
    lines.add(
      "static inline uint64_t " & n.regName & "(" & ctxType & "* ctx, " & n.fnType &
        " fn, void* user_data) {"
    )
    lines.add(
      "    " & n.boxType & "* box = (" & n.boxType & "*)malloc(sizeof(" & n.boxType &
        "));"
    )
    lines.add("    if (!box) return 0;")
    lines.add("    box->fn = fn;")
    lines.add("    box->user_data = user_data;")
    lines.add(
      "    uint64_t id = " & libName & "_add_event_listener(ctx->ptr, \"" & ev.wireName &
        "\", " & n.tramp & ", box);"
    )
    lines.add("    if (id == 0) { free(box); return 0; }")
    lines.add("    if (ctx->listeners_len == ctx->listeners_cap) {")
    lines.add("        size_t ncap = ctx->listeners_cap ? ctx->listeners_cap * 2 : 4;")
    lines.add(
      "        " & ctxType & "Listener* grown = (" & ctxType &
        "Listener*)realloc(ctx->listeners, ncap * sizeof(" & ctxType & "Listener));"
    )
    lines.add(
      "        if (!grown) { " & libName &
        "_remove_event_listener(ctx->ptr, id); free(box); return 0; }"
    )
    lines.add("        ctx->listeners = grown;")
    lines.add("        ctx->listeners_cap = ncap;")
    lines.add("    }")
    lines.add("    ctx->listeners[ctx->listeners_len].id = id;")
    lines.add("    ctx->listeners[ctx->listeners_len].box = box;")
    lines.add("    ctx->listeners_len++;")
    lines.add("    return id;")
    lines.add("}")
    lines.add("")
  lines.add(
    "static inline bool " & libName & "_ctx_remove_event_listener(" & ctxType &
      "* ctx, uint64_t id) {"
  )
  lines.add("    if (id == 0) return false;")
  lines.add("    int rc = " & libName & "_remove_event_listener(ctx->ptr, id);")
  lines.add("    for (size_t i = 0; i < ctx->listeners_len; i++) {")
  lines.add("        if (ctx->listeners[i].id == id) {")
  lines.add("            free(ctx->listeners[i].box);")
  lines.add("            ctx->listeners[i] = ctx->listeners[ctx->listeners_len - 1];")
  lines.add("            ctx->listeners_len--;")
  lines.add("            break;")
  lines.add("        }")
  lines.add("    }")
  lines.add("    return rc == 0;")
  lines.add("}")
  lines.add("")

proc emitProcWrapper(
    lines: var seq[string],
    reg: var CTypeReg,
    ctxType, libType, libName: string,
    m: FFIProcMeta,
) =
  ## Reply trampoline + wrapper: `<lib>_ctx_<name>`, or `<lib>_static_<name>` for a
  ## static; `<lib>_<name>` itself is the raw symbol the dylib exports.
  let isStatic = m.isStatic()
  let stripped = stripLibPrefix(m.procName, libName)
  let reqName = reqStructName(m)
  let retC = cReturnType(reg, m)
  let retFree = freeFn(reg, retC)
  let (params, assigns) = buildReqParams(reg, m.extraParams)
  let methodPascal = snakeToPascalCase(stripped)
  let fnType = libType & methodPascal & "ReplyFn"
  let boxType = libType & methodPascal & "CallBox"
  let tramp = libName & "_" & stripped & "_reply_trampoline"

  lines.add(
    "typedef void (*" & fnType & ")(int err_code, const " & retC &
      "* reply, const char* err_msg, void* user_data);"
  )
  emitCallBox(lines, fnType, boxType)
  emitReplyTrampolineHead(lines, tramp, boxType, "FFI call failed")
  lines.add("    char* err = NULL;")
  lines.add("    " & retC & " out;")
  lines.add("    memset(&out, 0, sizeof(out));")
  lines.add(
    "    int dec = nimffi_decode_from_buf(" & libName & "_decv_" & cToken(retC) &
      ", (const uint8_t*)msg, len, &out, &err);"
  )
  lines.add("    if (dec != 0) {")
  lines.add("        box->fn(-1, NULL, err ? err : \"decode failed\", box->user_data);")
  lines.add("        free(err);")
  # Reclaim fields a partial decode allocated (out is zeroed).
  if retFree.len > 0:
    lines.add("        " & retFree & "(&out);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    box->fn(NIMFFI_RET_OK, &out, NULL, box->user_data);")
  if retFree.len > 0:
    lines.add("    " & retFree & "(&out);")
  lines.add("    free(box);")
  lines.add("}")

  let head =
    if isStatic:
      "static inline int " & libName & "_static_" & stripped & "("
    else:
      "static inline int " & libName & "_ctx_" & stripped & "(const " & ctxType &
        "* ctx, "
  let sig =
    if params.len > 0:
      head & params.join(", ") & ", " & fnType & " on_reply, void* user_data) {"
    else:
      head & fnType & " on_reply, void* user_data) {"
  lines.add(renderBlockDocComment(m.doc))
  lines.add(sig)
  lines.add("    " & reqName & " ffi_req;")
  lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
  for a in assigns:
    lines.add(a)
  lines.add("    uint8_t* req_buf = NULL;")
  lines.add("    size_t req_len = 0;")
  lines.add("    char* err = NULL;")
  lines.add(
    "    if (nimffi_encode_to_buf(" & libName & "_encv_" & cToken(reqName) &
      ", &ffi_req, &req_buf, &req_len, &err) != 0) {"
  )
  lines.add(
    "        if (on_reply) on_reply(-1, NULL, err ? err : \"encode failed\", user_data);"
  )
  lines.add("        free(err);")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add(
    "    " & boxType & "* box = (" & boxType & "*)malloc(sizeof(" & boxType & "));"
  )
  lines.add("    if (!box) {")
  lines.add("        free(req_buf);")
  lines.add("        if (on_reply) on_reply(-1, NULL, \"out of memory\", user_data);")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("    box->fn = on_reply;")
  lines.add("    box->user_data = user_data;")
  let ctxArg = if isStatic: "" else: "ctx->ptr, "
  lines.add(
    "    int ret = " & m.procName & "(" & ctxArg & tramp & ", box, req_buf, req_len);"
  )
  lines.add("    free(req_buf);")
  lines.add("    if (ret == NIMFFI_RET_MISSING_CALLBACK) {")
  lines.add(
    "        if (on_reply) on_reply(-1, NULL, \"RET_MISSING_CALLBACK (internal error)\", user_data);"
  )
  lines.add("        free(box);")
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("    return 0;")
  lines.add("}")
  lines.add("")

proc newCTypeReg(
    libName, libType: string, types: seq[FFITypeMeta], procs: seq[FFIProcMeta]
): CTypeReg =
  var reg = CTypeReg(libName: libName, libType: libType)
  for t in types:
    reg.typeTable[t.name] = t
  for p in procs:
    if p.kind != FFIKind.DTOR:
      let rt = reqTypeMeta(p)
      reg.typeTable[rt.name] = rt
  return reg

proc monomorphiseAll(
    reg: var CTypeReg,
    types: seq[FFITypeMeta],
    procs, replyProcs: seq[FFIProcMeta],
    events: seq[FFIEventMeta],
): tuple[reqTypes, respTypes: seq[string]] =
  ## Runs every type, Req, return type and event payload through ensureCType,
  ## returning the Req and response C type names the buffer adapters need.
  for t in types:
    discard ensureCType(reg, t.name)
  var reqTypes: seq[string] = @[]
  for p in procs:
    if p.kind != FFIKind.DTOR:
      let n = reqStructName(p)
      discard ensureCType(reg, n)
      reqTypes.add(n)
  var respTypes: seq[string] = @[]
  for p in replyProcs:
    respTypes.add(cReturnType(reg, p))
  for ev in events:
    discard ensureCType(reg, ev.payloadTypeName)
  return (reqTypes, respTypes)

func constDeclLines(consts: seq[FFIConstMeta]): seq[string] =
  ## `{.ffiConst.}` values as typed `static const` definitions; shared by the
  ## CBOR and `abi = c` headers.
  if consts.len == 0:
    return @[]
  var lines = @[
    "/* ============================================================ */",
    "/* Generated constants                                          */",
    "/* ============================================================ */", "",
  ]
  for c in consts:
    let t = parseFFIType(c.typeName)
    let name = identToUpperSnake(c.name)
    let value = cConstValue(t, c.value)
    case t.kind
    of ftStr:
      lines.add("static const char* const " & name & " = " & value & ";")
    of ftScalar:
      lines.add(
        "static const " & scalarCInfoTable[t.scalar].cType & " " & name & " = " & value &
          ";"
      )
    else:
      discard
  lines.add("")
  return lines

func generateCPreludeHeader*(): string =
  ## The library-agnostic `nim_ffi_prelude.h`, emitted verbatim.
  return HeaderPreludeTpl & "\n"

func generateCCborHeader*(): string =
  ## The library-agnostic `nim_ffi_cbor.h`, emitted verbatim.
  return CborHelpersTpl & "\n"

proc generateCLibHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
): string =
  ## The `<lib>.h` header: library structs, monomorphised codecs and async API.
  let classified = classifyProcs(procs)
  let ctors = classified.ctors
  let libType = libTypeName(ctors, libName)
  let ctxType = libType & "Ctx"

  var reg = newCTypeReg(libName, libType, types, procs)
  let (reqTypes, respTypes) =
    monomorphiseAll(reg, types, procs, classified.replyProcs(), events)

  let guard = "NIM_FFI_LIB_" & libName.toUpperAscii() & "_H_INCLUDED"
  var lines: seq[string] = @[]
  lines.add("#ifndef " & guard)
  lines.add("#define " & guard)
  lines.add("#include \"" & CborHeaderName & "\"")
  lines.add("")

  lines.add(constDeclLines(consts))

  lines.add("/* ============================================================ */")
  lines.add("/* Generated types (user-declared + per-proc request envelopes) */")
  lines.add("/* ============================================================ */")
  lines.add("")
  for decl in reg.decls:
    lines.add(decl)
  lines.add("")
  for codec in reg.codecs:
    lines.add(codec)
  lines.add("")

  lines.add("/* ============================================================ */")
  lines.add("/* C ABI declarations (symbols exported by the Nim dylib)       */")
  lines.add("/* ============================================================ */")
  lines.add("#ifdef __cplusplus")
  lines.add("extern \"C\" {")
  lines.add("#endif")
  lines.add("")
  for p in procs:
    lines.add(renderBlockDocComment(p.doc))
    case p.kind
    of FFIKind.FFI:
      lines.add(
        "int " & p.procName & "(void* ctx, FFICallback callback, void* user_data, " &
          "const uint8_t* req_cbor, size_t req_cbor_len);"
      )
    of FFIKind.STATIC:
      lines.add(
        "int " & p.procName & "(FFICallback callback, void* user_data, " &
          "const uint8_t* req_cbor, size_t req_cbor_len);"
      )
    of FFIKind.CTOR:
      lines.add(
        "void* " & p.procName & "(const uint8_t* req_cbor, size_t req_cbor_len, " &
          "FFICallback callback, void* user_data);"
      )
    of FFIKind.DTOR:
      lines.add("int " & p.procName & "(void* ctx);")
  lines.add(
    "uint64_t " & libName & "_add_event_listener(void* ctx, const char* event_name, " &
      "FFICallback callback, void* user_data);"
  )
  lines.add(
    "int " & libName & "_remove_event_listener(void* ctx, uint64_t listener_id);"
  )
  lines.add("")
  lines.add("#ifdef __cplusplus")
  lines.add("} /* extern \"C\" */")
  lines.add("#endif")
  lines.add("")

  # Per-Req encode / per-response decode void* adapters for the buffer drivers.
  var adaptersDone = initHashSet[string]()
  lines.add("/* CBOR buffer adapters (typed codec → void* driver signature) */")
  for n in reqTypes:
    let tok = cToken(n)
    if ("enc" & tok) notin adaptersDone:
      adaptersDone.incl("enc" & tok)
      lines.add(
        "static inline CborError " & libName & "_encv_" & tok &
          "(CborEncoder* e, const void* v) { return " & reg.libName & "_enc_" & n &
          "(e, (const " & n & "*)v); }"
      )
  var respSet = respTypes
  respSet.add("NimFfiStr") # ctor address payload
  for n in respSet:
    let tok = cToken(n)
    if ("dec" & tok) notin adaptersDone:
      adaptersDone.incl("dec" & tok)
      lines.add(
        "static inline CborError " & libName & "_decv_" & tok &
          "(CborValue* it, void* v) { return " & decFn(reg, n) & "(it, (" & n & "*)v); }"
      )
  lines.add("")

  emitEventMachinery(lines, reg, libType, libName, events)
  emitContextStruct(lines, ctxType, events)
  emitConstructors(lines, reg, ctxType, libType, libName, ctors)
  emitDestructor(lines, ctxType, libName, classified.dtor, events)
  emitListenerApi(lines, ctxType, libType, libName, events)
  for m in classified.replyProcs():
    emitProcWrapper(lines, reg, ctxType, libType, libName, m)

  lines.add("#endif /* " & guard & " */")
  return lines.join("\n") & "\n"

proc generateCCMakeLists*(libName, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  return CMakeListsTpl.multiReplace(("{{LIB}}", libName), ("{{SRC}}", src))

# `abi = c` binding: structs are the C ABI directly (no CBOR), matching the Nim-side wire layout byte-for-byte.

const AbiCPtrType = "void*"
const AbiCMakeListsTpl = staticRead("templates/c/CMakeLists_abi.txt.tpl")

func abiLeafCType(t: string): tuple[ok: bool, cType: string] =
  ## Nim leaf type → `abi = c` wire C type; `ok` is false for composites.
  return
    case t
    of "int", "int64":
      (true, "int64_t")
    of "int32":
      (true, "int32_t")
    of "int16":
      (true, "int16_t")
    of "int8":
      (true, "int8_t")
    of "uint", "uint64":
      (true, "uint64_t")
    of "uint32":
      (true, "uint32_t")
    of "uint16":
      (true, "uint16_t")
    of "uint8", "byte":
      (true, "uint8_t")
    of "bool":
      (true, "bool")
    of "float", "float64":
      (true, "double")
    of "float32":
      (true, "float")
    of "pointer":
      (true, AbiCPtrType)
    of "string", "cstring":
      (true, "const char*")
    else:
      (false, "")

type AbiReg = object
  typeTable: Table[string, FFITypeMeta]
  emitted: HashSet[string]
  decls: seq[string]

proc ensureAbiStruct(reg: var AbiReg, typeName: string)

proc abiWireValueCType(reg: var AbiReg, nimType: string): string =
  ## `abi = c` C type for a value-position field (a top-level `seq` splits in two).
  let t = nimType.strip()
  if t.startsWith("ptr ") or t == "pointer":
    return AbiCPtrType
  let leaf = abiLeafCType(t)
  if leaf.ok:
    return leaf.cType
  var optInner = genericInnerType(t, "Option[")
  if optInner.len == 0:
    optInner = genericInnerType(t, "Maybe[")
  if optInner.len > 0:
    return abiWireValueCType(reg, optInner.strip()) & "*"
  if genericInnerType(t, "seq[").len > 0:
    raise newException(
      ValueError, "abi = c: `seq` has no single-field wire form, so it can't nest: " & t
    )
  if genericInnerType(t, "array[").len > 0:
    raise newException(
      ValueError, "abi = c: array fields are not yet supported by the C backend: " & t
    )
  if t in reg.typeTable:
    ensureAbiStruct(reg, t)
    return t
  raise newException(ValueError, "abi = c: unknown field type: " & t)

proc abiFieldDecls(reg: var AbiReg, name, nimType: string): seq[string] =
  let seqInner = genericInnerType(nimType.strip(), "seq[")
  if seqInner.len > 0:
    let elemC = abiWireValueCType(reg, seqInner.strip())
    return @[elemC & "* " & name & "_items;", "ptrdiff_t " & name & "_len;"]
  return @[abiWireValueCType(reg, nimType) & " " & name & ";"]

proc emitAbiStruct(reg: var AbiReg, t: FFITypeMeta) =
  var members: seq[string] = @[]
  for f in t.fields:
    for line in abiFieldDecls(reg, f.name, f.typeName):
      members.add("    " & line)
  if members.len == 0:
    members.add("    uint8_t _placeholder; /* C forbids empty structs */")
  reg.decls.add("typedef struct {\n" & members.join("\n") & "\n} " & t.name & ";")

proc ensureAbiStruct(reg: var AbiReg, typeName: string) =
  if typeName in reg.emitted:
    return
  reg.emitted.incl(typeName)
  if typeName in reg.typeTable:
    emitAbiStruct(reg, reg.typeTable[typeName])
  else:
    reg.decls.add("/* unknown type referenced: " & typeName & " */")

proc newAbiReg(types: seq[FFITypeMeta], procs: seq[FFIProcMeta]): AbiReg =
  var reg = AbiReg()
  for t in types:
    reg.typeTable[t.name] = t
  for p in procs:
    if p.kind != FFIKind.DTOR and not p.scalarFastPath:
      let rt = reqTypeMeta(p)
      reg.typeTable[rt.name] = rt
  return reg

func abiParamByValue(nimType: string, ridesAsPtr: bool): bool =
  ## Scalars/pointers/string views pass by value; aggregates by const pointer.
  if ridesAsPtr:
    return true
  return abiLeafCType(nimType.strip()).ok

proc abiReqParamsAndAssigns(
    reg: var AbiReg, extraParams: seq[FFIParamMeta]
): tuple[params, assigns: seq[string]] =
  var params, assigns: seq[string] = @[]
  for ep in extraParams:
    let rides = ep.ridesAsPtr()
    let cType =
      if rides:
        AbiCPtrType
      else:
        abiWireValueCType(reg, ep.typeName)
    if abiParamByValue(ep.typeName, rides):
      params.add(cType & " " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = " & ep.name & ";")
    else:
      params.add("const " & cType & "* " & ep.name)
      assigns.add("    ffi_req." & ep.name & " = *" & ep.name & ";")
  return (params, assigns)

proc abiMethodReplyInfo(
    reg: var AbiReg, libType: string, m: FFIProcMeta
): tuple[fnType, replyParam: string] =
  ## Reply-callback typedef name plus the C type of its `reply` argument.
  let pascal = snakeToPascalCase(stripLibPrefix(m.procName, m.libName))
  let fnType = libType & pascal & "ReplyFn"
  if m.returnRidesAsPtr():
    raise newException(
      ValueError,
      "abi = c: handle/pointer returns are not yet supported by the C backend: " &
        m.procName,
    )
  let rt = m.returnTypeName.strip()
  let leaf = abiLeafCType(rt)
  let replyParam =
    if rt == "string" or rt == "cstring":
      "const char*"
    elif leaf.ok:
      "const " & leaf.cType & "*"
    else:
      ensureAbiStruct(reg, rt)
      "const " & rt & "*"
  return (fnType, replyParam)

proc emitAbiReplyTypedefs(
    lines: var seq[string], reg: var AbiReg, libType: string, methods: seq[FFIProcMeta]
) =
  for m in methods:
    let info = abiMethodReplyInfo(reg, libType, m)
    lines.add(
      "typedef void (*" & info.fnType & ")(int err_code, " & info.replyParam &
        " reply, const char* err_msg, void* user_data);"
    )

func abiScalarRawFnName(libType: string): string =
  ## Raw-bytes callback typedef a scalar-fast-path export takes.
  return libType & "ScalarRawFn"

const abiScalarDupCStr = "nimffi_abi_dup_cstr_n"

func abiScalarDupHelper(): seq[string] =
  ## CBOR-free twin of `nimffi_dup_cstr_n`, include-guarded so two `abi = c`
  ## headers can co-exist in one TU.
  return @[
    "#ifndef NIMFFI_ABI_DUP_CSTR_N",
    "#define NIMFFI_ABI_DUP_CSTR_N",
    "/* NUL-terminated copy of a length-delimited byte run; NULL if it can't. */",
    "static inline char* " & abiScalarDupCStr & "(const char* s, size_t n) {",
    "    if (n == SIZE_MAX) return NULL;",
    "    char* p = (char*)malloc(n + 1);",
    "    if (p) {",
    "        if (n > 0) memcpy(p, s, n);",
    "        p[n] = '\\0';",
    "    }",
    "    return p;",
    "}",
    "#endif",
  ]

func abiScalarArgParams(m: FFIProcMeta): seq[string] =
  var params: seq[string] = @[]
  for ep in m.extraParams:
    params.add(abiLeafCType(ep.typeName.strip()).cType & " " & ep.name)
  return params

proc emitAbiExternDecls(
    lines: var seq[string],
    reg: var AbiReg,
    libName, libType: string,
    procs: seq[FFIProcMeta],
) =
  let createRawFn = libType & "CreateRawFn"
  var haveCtor, haveScalar = false
  for p in procs:
    if p.kind == FFIKind.CTOR:
      haveCtor = true
    if p.scalarFastPath:
      haveScalar = true
  if haveCtor:
    lines.add(
      "typedef void (*" & createRawFn &
        ")(int err_code, const char* ctx_addr, const char* err_msg, void* user_data);"
    )
  if haveScalar:
    lines.add(
      "/* Raw reply of a scalar-fast-path export: `msg`/`len` are bytes (a string"
    )
    lines.add("   return's UTF-8, or the 8-byte native-endian scalar image), not")
    lines.add("   NUL-terminated and valid only for the duration of the call. */")
    lines.add(
      "typedef void (*" & abiScalarRawFnName(libType) &
        ")(int caller_ret, char* msg, size_t len, void* user_data);"
    )
    for l in abiScalarDupHelper():
      lines.add(l)
  lines.add("#ifdef __cplusplus")
  lines.add("extern \"C\" {")
  lines.add("#endif")
  lines.add("")
  for p in procs:
    lines.add(renderBlockDocComment(p.doc))
    case p.kind
    of FFIKind.FFI:
      if p.scalarFastPath:
        var params =
          @["void* ctx", abiScalarRawFnName(libType) & " callback", "void* user_data"]
        params.add(abiScalarArgParams(p))
        lines.add("int " & p.procName & "(" & params.join(", ") & ");")
      else:
        let info = abiMethodReplyInfo(reg, libType, p)
        lines.add(
          "int " & p.procName & "(void* ctx, " & info.fnType &
            " on_reply, void* user_data, const " & reqStructName(p) & "* req);"
        )
    of FFIKind.STATIC:
      let info = abiMethodReplyInfo(reg, libType, p)
      lines.add(
        "int " & p.procName & "(" & info.fnType & " on_reply, void* user_data, const " &
          reqStructName(p) & "* req);"
      )
    of FFIKind.CTOR:
      lines.add(
        "void* " & p.procName & "(const " & reqStructName(p) & "* req, " & createRawFn &
          " on_created, void* user_data);"
      )
    of FFIKind.DTOR:
      lines.add("int " & p.procName & "(void* ctx);")
  lines.add("")
  lines.add("#ifdef __cplusplus")
  lines.add("} /* extern \"C\" */")
  lines.add("#endif")
  lines.add("")

proc emitAbiCtxAndCtor(
    lines: var seq[string],
    reg: var AbiReg,
    libName, libType, ctxType: string,
    ctors: seq[FFIProcMeta],
) =
  lines.add("typedef struct {")
  lines.add("    void* ptr;")
  lines.add("} " & ctxType & ";")
  lines.add("")
  if ctors.len == 0:
    return
  let createFn = libType & "CreateFn"
  let createBox = libType & "CreateBox"
  let createRawFn = libType & "CreateRawFn"
  let tramp = libName & "_create_trampoline"
  lines.add(
    "typedef void (*" & createFn & ")(int err_code, " & ctxType &
      "* ctx, const char* err_msg, void* user_data);"
  )
  lines.add(
    "typedef struct { " & createFn & " fn; void* user_data; } " & createBox & ";"
  )
  lines.add(
    "static void " & tramp &
      "(int ret, const char* ctx_addr, const char* err_msg, void* ud) {"
  )
  lines.add("    " & createBox & "* box = (" & createBox & "*)ud;")
  lines.add("    if (!box) return;")
  lines.add("    if (ret == NIMFFI_RET_STALE_WARN) return;")
  lines.add("    if (!box->fn) { free(box); return; }")
  lines.add("    if (ret != 0) {")
  lines.add(
    "        box->fn(ret, NULL, err_msg ? err_msg : \"FFI create failed\", box->user_data);"
  )
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    char* endp = NULL;")
  lines.add("    unsigned long long a = ctx_addr ? strtoull(ctx_addr, &endp, 10) : 0;")
  lines.add("    bool ok = ctx_addr && *ctx_addr && endp && *endp == '\\0';")
  lines.add("    if (!ok) {")
  lines.add(
    "        box->fn(-1, NULL, \"FFI create returned non-numeric address\", box->user_data);"
  )
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add(
    "    " & ctxType & "* ctx = (" & ctxType & "*)calloc(1, sizeof(" & ctxType & "));"
  )
  lines.add("    if (!ctx) {")
  lines.add("        box->fn(-1, NULL, \"out of memory\", box->user_data);")
  lines.add("        free(box);")
  lines.add("        return;")
  lines.add("    }")
  lines.add("    ctx->ptr = (void*)(uintptr_t)a;")
  lines.add("    box->fn(NIMFFI_RET_OK, ctx, NULL, box->user_data);")
  lines.add("    free(box);")
  lines.add("}")
  lines.add("")
  for ctor in ctors:
    let reqStruct = reqStructName(ctor)
    let (params, assigns) = abiReqParamsAndAssigns(reg, ctor.extraParams)
    let head = "static inline int " & libName & "_ctx_create("
    let sig =
      if params.len > 0:
        head & params.join(", ") & ", " & createFn & " on_created, void* user_data) {"
      else:
        head & createFn & " on_created, void* user_data) {"
    lines.add(renderBlockDocComment(ctor.doc))
    lines.add(sig)
    lines.add("    " & reqStruct & " ffi_req;")
    lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
    for a in assigns:
      lines.add(a)
    lines.add(
      "    " & createBox & "* box = (" & createBox & "*)malloc(sizeof(" & createBox &
        "));"
    )
    lines.add("    if (!box) {")
    lines.add(
      "        if (on_created) on_created(-1, NULL, \"out of memory\", user_data);"
    )
    lines.add("        return -1;")
    lines.add("    }")
    lines.add("    box->fn = on_created;")
    lines.add("    box->user_data = user_data;")
    lines.add("    (void)" & ctor.procName & "(&ffi_req, " & tramp & ", box);")
    lines.add("    return 0;")
    lines.add("}")
    lines.add("")

proc emitAbiProcWrapper(
    lines: var seq[string],
    reg: var AbiReg,
    ctxType, libName, libType: string,
    m: FFIProcMeta,
) =
  let isStatic = m.isStatic()
  let stripped = stripLibPrefix(m.procName, m.libName)
  let reqStruct = reqStructName(m)
  let info = abiMethodReplyInfo(reg, libType, m)
  let (params, assigns) = abiReqParamsAndAssigns(reg, m.extraParams)
  let head =
    if isStatic:
      "static inline int " & libName & "_static_" & stripped & "("
    else:
      "static inline int " & libName & "_ctx_" & stripped & "(const " & ctxType &
        "* ctx, "
  let sig =
    if params.len > 0:
      head & params.join(", ") & ", " & info.fnType & " on_reply, void* user_data) {"
    else:
      head & info.fnType & " on_reply, void* user_data) {"
  lines.add(renderBlockDocComment(m.doc))
  lines.add(sig)
  lines.add("    " & reqStruct & " ffi_req;")
  lines.add("    memset(&ffi_req, 0, sizeof(ffi_req));")
  for a in assigns:
    lines.add(a)
  let ctxArg = if isStatic: "" else: "ctx->ptr, "
  lines.add(
    "    return " & m.procName & "(" & ctxArg & "on_reply, user_data, &ffi_req);"
  )
  lines.add("}")
  lines.add("")

func abiScalarOkLines(m: FFIProcMeta, fnType: string): seq[string] =
  ## Trampoline RET_OK branch. A string return rides as its own UTF-8; every
  ## other scalar is the 8-byte image `ffiRawRetBytes` packs (ints
  ## sign-extended, floats widened to double, bool as 0/1).
  let rt = m.returnTypeName.strip()
  if rt == "string" or rt == "cstring":
    return @[
      "    char* reply = " & abiScalarDupCStr & "(msg ? msg : \"\", msg ? len : 0);",
      "    if (!reply) {",
      "        fn(NIMFFI_RET_ERR, \"\", \"out of memory\", user_data);",
      "        return;", "    }", "    fn(NIMFFI_RET_OK, reply, \"\", user_data);",
      "    free(reply);",
    ]
  var lines = @[
    "    uint64_t slot = 0;", "    if (!msg || len != sizeof(slot)) {",
    "        fn(NIMFFI_RET_ERR, NULL, \"scalar reply: unexpected payload size\", user_data);",
    "        return;", "    }", "    memcpy(&slot, msg, sizeof(slot));",
  ]
  let cType = abiLeafCType(rt).cType
  case rt
  of "int", "int64":
    lines.add("    int64_t reply;")
    lines.add("    memcpy(&reply, &slot, sizeof(reply));")
  of "int8", "int16", "int32":
    lines.add("    int64_t wide;")
    lines.add("    memcpy(&wide, &slot, sizeof(wide));")
    lines.add("    " & cType & " reply = (" & cType & ")wide;")
  of "uint", "uint64":
    lines.add("    uint64_t reply = slot;")
  of "uint8", "uint16", "uint32", "byte":
    lines.add("    " & cType & " reply = (" & cType & ")slot;")
  of "bool":
    lines.add("    bool reply = slot != 0;")
  of "float", "float64":
    lines.add("    double reply;")
    lines.add("    memcpy(&reply, &slot, sizeof(reply));")
  of "float32":
    lines.add("    double wide;")
    lines.add("    memcpy(&wide, &slot, sizeof(wide));")
    lines.add("    float reply = (float)wide;")
  else:
    raise newException(
      ValueError, "abi = c: unexpected scalar-fast-path return type: " & rt
    )
  lines.add("    fn(NIMFFI_RET_OK, &reply, \"\", user_data);")
  return lines

proc emitAbiScalarMethod(
    lines: var seq[string],
    reg: var AbiReg,
    ctxType, libName, libType: string,
    m: FFIProcMeta,
) =
  ## Args go inline to the raw export and a trampoline adapts the raw-bytes
  ## reply into the typed `ReplyFn` surface. The trampoline frees the callback
  ## box, relying on the dylib invoking it exactly once on every path.
  let stripped = stripLibPrefix(m.procName, m.libName)
  let pascal = snakeToPascalCase(stripped)
  let info = abiMethodReplyInfo(reg, libType, m)
  let boxType = libType & pascal & "ScalarBox"
  let tramp = m.procName & "_scalar_reply"
  let isStr = m.returnTypeName.strip() in ["string", "cstring"]
  let errReply = if isStr: "\"\"" else: "NULL"
  lines.add(
    "typedef struct { " & info.fnType & " fn; void* user_data; } " & boxType & ";"
  )
  lines.add(
    "static void " & tramp & "(int caller_ret, char* msg, size_t len, void* ud) {"
  )
  lines.add("    " & boxType & "* box = (" & boxType & "*)ud;")
  lines.add("    if (!box) return;")
  lines.add("    " & info.fnType & " fn = box->fn;")
  lines.add("    void* user_data = box->user_data;")
  lines.add("    free(box);")
  lines.add("    if (!fn) return;")
  lines.add("    if (caller_ret != NIMFFI_RET_OK) {")
  lines.add(
    "        char* em = " & abiScalarDupCStr & "(msg ? msg : \"\", msg ? len : 0);"
  )
  lines.add(
    "        fn(caller_ret, " & errReply & ", em ? em : \"FFI call failed\", user_data);"
  )
  lines.add("        free(em);")
  lines.add("        return;")
  lines.add("    }")
  for l in abiScalarOkLines(m, info.fnType):
    lines.add(l)
  lines.add("}")
  lines.add("")
  let params = abiScalarArgParams(m)
  let head =
    "static inline int " & libName & "_ctx_" & stripped & "(const " & ctxType & "* ctx, "
  let sig =
    if params.len > 0:
      head & params.join(", ") & ", " & info.fnType & " on_reply, void* user_data) {"
    else:
      head & info.fnType & " on_reply, void* user_data) {"
  lines.add(renderBlockDocComment(m.doc))
  lines.add(sig)
  lines.add(
    "    " & boxType & "* box = (" & boxType & "*)malloc(sizeof(" & boxType & "));"
  )
  lines.add("    if (!box) {")
  lines.add(
    "        if (on_reply) on_reply(-1, " & errReply & ", \"out of memory\", user_data);"
  )
  lines.add("        return -1;")
  lines.add("    }")
  lines.add("    box->fn = on_reply;")
  lines.add("    box->user_data = user_data;")
  var callArgs = @["ctx->ptr", tramp, "box"]
  for ep in m.extraParams:
    callArgs.add(ep.name)
  lines.add("    return " & m.procName & "(" & callArgs.join(", ") & ");")
  lines.add("}")
  lines.add("")

proc generateCAbiLibHeader*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
): string =
  if events.len > 0:
    raise newException(
      ValueError, "abi = c: the C backend does not yet support {.ffiEvent.} listeners"
    )
  let classified = classifyProcs(procs)
  let libType = libTypeName(classified.ctors, libName)
  let ctxType = libType & "Ctx"

  var reg = newAbiReg(types, procs)
  for t in types:
    ensureAbiStruct(reg, t.name)
  for p in procs:
    if p.kind != FFIKind.DTOR and not p.scalarFastPath:
      ensureAbiStruct(reg, reqStructName(p))

  let guard = "NIM_FFI_LIB_" & libName.toUpperAscii() & "_C_ABI_H_INCLUDED"
  var lines: seq[string] = @[]
  lines.add("#ifndef " & guard)
  lines.add("#define " & guard)
  lines.add("#include <stdint.h>")
  lines.add("#include <stddef.h>")
  lines.add("#include <stdbool.h>")
  lines.add("#include <stdlib.h>")
  lines.add("#include <string.h>")
  lines.add("")
  lines.add("#define NIMFFI_RET_OK 0")
  lines.add("#define NIMFFI_RET_ERR 1")
  lines.add("#define NIMFFI_RET_MISSING_CALLBACK 2")
  lines.add("/* Non-terminal: the request is still running. Fires every ~5s with `msg`")
  lines.add(
    "   carrying the elapsed milliseconds as decimal text; always followed by a"
  )
  lines.add("   terminal RET_OK/RET_ERR. Ignore it unless you want progress. */")
  lines.add("#define NIMFFI_RET_STALE_WARN 3")
  lines.add("")
  lines.add(constDeclLines(consts))
  lines.add(
    "/* `abi = c` wire structs — the C ABI. Strings are borrowed, NUL-terminated"
  )
  lines.add("   `const char*` valid only for the duration of the call they cross. */")
  for decl in reg.decls:
    lines.add(decl)
  lines.add("")

  emitAbiReplyTypedefs(lines, reg, libType, classified.replyProcs())
  lines.add("")
  emitAbiExternDecls(lines, reg, libName, libType, procs)

  lines.add("/* High-level context wrapper */")
  emitAbiCtxAndCtor(lines, reg, libName, libType, ctxType, classified.ctors)
  # abi = c has no events, so the destructor is the CBOR one minus the listener sweep.
  emitDestructor(lines, ctxType, libName, classified.dtor, @[])
  # A static is never scalar-fast-path (`isScalarOnly` gates on FFIKind.FFI).
  for m in classified.replyProcs():
    if m.scalarFastPath:
      emitAbiScalarMethod(lines, reg, ctxType, libName, libType, m)
    else:
      emitAbiProcWrapper(lines, reg, ctxType, libName, libType, m)

  lines.add("#endif /* " & guard & " */")
  return lines.join("\n") & "\n"

proc generateCAbiCMakeLists*(libName, nimSrcRelPath: string): string =
  let src = nimSrcRelPath.replace("\\", "/")
  return AbiCMakeListsTpl.multiReplace(("{{LIB}}", libName), ("{{SRC}}", src))

func libWireFormat(procs: seq[FFIProcMeta], types: seq[FFITypeMeta]): ABIFormat =
  ## The single wire format the C header targets (no mixing in one header).
  var seen: set[ABIFormat] = {}
  for p in procs:
    if p.kind != FFIKind.DTOR:
      seen.incl(p.abiFormat)
  if seen.len == 0:
    for t in types:
      seen.incl(t.abiFormat)
  if seen.len > 1:
    raise newException(
      ValueError,
      "abi = c/cbor mismatch: a C library must use one ABI format for all its " &
        "procs and types; a mixed header is not supported",
    )
  return (if ABIFormat.C in seen: ABIFormat.C else: ABIFormat.Cbor)

proc generateCBindings*(
    procs: seq[FFIProcMeta],
    types: seq[FFITypeMeta],
    libName: string,
    outputDir: string,
    nimSrcRelPath: string,
    events: seq[FFIEventMeta] = @[],
    consts: seq[FFIConstMeta] = @[],
) =
  ## Emits the C binding for `libName`, picking the `abi = c` or CBOR shape.
  createDir(outputDir)
  case libWireFormat(procs, types)
  of ABIFormat.C:
    writeFile(
      outputDir / (libName & ".h"),
      generateCAbiLibHeader(procs, types, libName, events, consts),
    )
    writeFile(
      outputDir / "CMakeLists.txt", generateCAbiCMakeLists(libName, nimSrcRelPath)
    )
  of ABIFormat.Cbor:
    writeFile(outputDir / PreludeHeaderName, generateCPreludeHeader())
    writeFile(outputDir / CborHeaderName, generateCCborHeader())
    writeFile(
      outputDir / (libName & ".h"),
      generateCLibHeader(procs, types, libName, events, consts),
    )
    writeFile(outputDir / "CMakeLists.txt", generateCCMakeLists(libName, nimSrcRelPath))
