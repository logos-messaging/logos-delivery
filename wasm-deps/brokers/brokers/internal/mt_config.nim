## Multi-thread broker configuration
## ---------------------------------
## Compile-time config records and macro-argument parsing for the
## multi-thread Event / Request brokers.
##
## The macro entry points accept optional kwargs:
##
##   EventBroker(mt, queueDepth = 1024, slabCapacity = 4096): ...
##   RequestBroker(mt, responseSlots = 64, maxResponseBytes = 4096): ...
##
## When no kwargs are supplied the existing module-level defaults in
## `mt_event_broker.nim` / `mt_request_broker.nim` are used unchanged.

{.push raises: [].}
{.push warning[UnreachableCode]: off.}

import std/[macros, strutils]

type
  MtEvtCfg* = object ## Resolved EventBroker(mt) capacity config.
    queueDepth*: int ## ring slots per listener bucket (power-of-2)
    slabCapacity*: int ## global slab cell count
    maxPayloadBytes*: int ## per-cell payload bytes
    maxDynamicPayloadBytes*: int
      ## ceiling for an auto-spilled (heap) payload that exceeds the fixed cell.
      ## Spill is always-on; this is a dev-chosen sanity cap, default high(uint32)
      ## (effectively unbounded). A payload above it is dropped (OOM/DoS backstop).
    freeListShards*: int ## sharded free-list partitions
    # Provenance — for the compile-time printout. "default" / "kwarg" /
    # "preset:<name>" / "auto:<reason>".
    queueDepthOrigin*: string
    slabCapacityOrigin*: string
    maxPayloadBytesOrigin*: string
    maxDynamicPayloadBytesOrigin*: string
    freeListShardsOrigin*: string

  MtReqCfg* = object ## Resolved RequestBroker(mt) capacity config.
    queueDepth*: int
    slabCapacity*: int
    maxPayloadBytes*: int
    maxDynamicPayloadBytes*: int
      ## ceiling for an auto-spilled request OR response payload. See MtEvtCfg.
    responseSlots*: int
    maxResponseBytes*: int
    freeListShards*: int
    queueDepthOrigin*: string
    slabCapacityOrigin*: string
    maxPayloadBytesOrigin*: string
    maxDynamicPayloadBytesOrigin*: string
    responseSlotsOrigin*: string
    maxResponseBytesOrigin*: string
    freeListShardsOrigin*: string

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

const
  # Default ceiling for heap-spilled payloads. high(uint32) ≈ 4 GiB — also the
  # intrinsic cap, since the cell/slot spill-length fields are uint32. Spill is
  # always-on; this only bounds how large a single spill may grow.
  DefaultMtMaxDynamicPayloadBytes* = int(high(uint32))

  DefaultMtEvtQueueDepth* = 256
  DefaultMtEvtSlabCapacity* = 1024
  DefaultMtEvtMaxPayloadBytes* = 1024
  DefaultMtEvtFreeListShards* = 4

  DefaultMtReqQueueDepth* = 256
  DefaultMtReqSlabCapacity* = 64
  DefaultMtReqMaxPayloadBytes* = 1024
  DefaultMtReqResponseSlots* = 256
  DefaultMtReqMaxResponseBytes* = 64 * 1024
  DefaultMtReqFreeListShards* = 2

# ---------------------------------------------------------------------------
# Built-in presets
# ---------------------------------------------------------------------------
#
# Named shorthand for capacity profiles. Recognised in the macro as
# `preset = <name>`.
#
#   defaultBalanced  same as omitting `preset`
#   fastBurst        bursty emit/request, small payload — wide ring/slab
#   largePayload    infrequent traffic with big payloads
#   tinyFootprint    rare traffic, embedded / memory-constrained
#
# Individual kwargs supplied alongside `preset =` override the preset's
# values (so you can pick a profile and tweak one field).

type BuiltinPreset* = enum
  bpDefaultBalanced = "defaultBalanced"
  bpFastBurst = "fastBurst"
  bpLargePayload = "largePayload"
  bpTinyFootprint = "tinyFootprint"

proc parseBuiltinPreset(name: string, n: NimNode): BuiltinPreset =
  case name
  of "defaultBalanced":
    bpDefaultBalanced
  of "fastBurst":
    bpFastBurst
  of "largePayload":
    bpLargePayload
  of "tinyFootprint":
    bpTinyFootprint
  else:
    error(
      "Unknown preset '" & name &
        "'. Built-in presets: defaultBalanced, fastBurst, largePayload, " &
        "tinyFootprint. (User-defined presets are not yet supported.)",
      n,
    )
    bpDefaultBalanced

proc applyEvtPreset(cfg: var MtEvtCfg, p: BuiltinPreset) =
  let tag = "preset:" & $p
  case p
  of bpDefaultBalanced:
    discard # already the default
  of bpFastBurst:
    cfg.queueDepth = 4096
    cfg.slabCapacity = 8192
    cfg.maxPayloadBytes = 256
    cfg.freeListShards = 8
  of bpLargePayload:
    cfg.queueDepth = 64
    cfg.slabCapacity = 128
    cfg.maxPayloadBytes = 64 * 1024
    cfg.freeListShards = 2
  of bpTinyFootprint:
    cfg.queueDepth = 32
    cfg.slabCapacity = 32
    cfg.maxPayloadBytes = 256
    cfg.freeListShards = 1
  cfg.queueDepthOrigin = tag
  cfg.slabCapacityOrigin = tag
  cfg.maxPayloadBytesOrigin = tag
  cfg.freeListShardsOrigin = tag

proc applyReqPreset(cfg: var MtReqCfg, p: BuiltinPreset) =
  let tag = "preset:" & $p
  case p
  of bpDefaultBalanced:
    discard
  of bpFastBurst:
    cfg.queueDepth = 4096
    cfg.slabCapacity = 256
    cfg.maxPayloadBytes = 256
    cfg.responseSlots = 1024
    cfg.maxResponseBytes = 4 * 1024
    cfg.freeListShards = 4
  of bpLargePayload:
    cfg.queueDepth = 64
    cfg.slabCapacity = 32
    cfg.maxPayloadBytes = 64 * 1024
    cfg.responseSlots = 64
    cfg.maxResponseBytes = 256 * 1024
    cfg.freeListShards = 2
  of bpTinyFootprint:
    cfg.queueDepth = 16
    cfg.slabCapacity = 8
    cfg.maxPayloadBytes = 256
    cfg.responseSlots = 16
    cfg.maxResponseBytes = 1024
    cfg.freeListShards = 1
  cfg.queueDepthOrigin = tag
  cfg.slabCapacityOrigin = tag
  cfg.maxPayloadBytesOrigin = tag
  cfg.responseSlotsOrigin = tag
  cfg.maxResponseBytesOrigin = tag
  cfg.freeListShardsOrigin = tag

proc defaultMtEvtCfg*(): MtEvtCfg =
  MtEvtCfg(
    queueDepth: DefaultMtEvtQueueDepth,
    slabCapacity: DefaultMtEvtSlabCapacity,
    maxPayloadBytes: DefaultMtEvtMaxPayloadBytes,
    maxDynamicPayloadBytes: DefaultMtMaxDynamicPayloadBytes,
    freeListShards: DefaultMtEvtFreeListShards,
    queueDepthOrigin: "default",
    slabCapacityOrigin: "default",
    maxPayloadBytesOrigin: "default",
    maxDynamicPayloadBytesOrigin: "default",
    freeListShardsOrigin: "default",
  )

proc defaultMtReqCfg*(): MtReqCfg =
  MtReqCfg(
    queueDepth: DefaultMtReqQueueDepth,
    slabCapacity: DefaultMtReqSlabCapacity,
    maxPayloadBytes: DefaultMtReqMaxPayloadBytes,
    maxDynamicPayloadBytes: DefaultMtMaxDynamicPayloadBytes,
    responseSlots: DefaultMtReqResponseSlots,
    maxResponseBytes: DefaultMtReqMaxResponseBytes,
    freeListShards: DefaultMtReqFreeListShards,
    queueDepthOrigin: "default",
    slabCapacityOrigin: "default",
    maxPayloadBytesOrigin: "default",
    maxDynamicPayloadBytesOrigin: "default",
    responseSlotsOrigin: "default",
    maxResponseBytesOrigin: "default",
    freeListShardsOrigin: "default",
  )

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc isPow2(n: int): bool {.inline.} =
  n > 0 and (n and (n - 1)) == 0

proc intValOrFail(n: NimNode, kw: string): int =
  ## Extract a compile-time int from a kwarg RHS. Errors clearly on
  ## non-int input.
  case n.kind
  of nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit, nnkInt64Lit, nnkUIntLit,
      nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit, nnkUInt64Lit:
    int(n.intVal)
  else:
    error("broker kwarg '" & kw & "' expects an integer literal, got " & $n.kind, n)
    0

# ---------------------------------------------------------------------------
# Kwarg parsing — EventBroker(mt)
# ---------------------------------------------------------------------------

const ValidEvtKwargs = [
  "queueDepth", "slabCapacity", "maxPayloadBytes", "maxDynamicPayloadBytes",
  "freeListShards",
]

proc applyEvtKwarg(cfg: var MtEvtCfg, kw: string, n: NimNode) =
  case kw
  of "queueDepth":
    let v = intValOrFail(n, kw)
    if not isPow2(v):
      error("EventBroker kwarg 'queueDepth' must be power-of-2, got " & $v, n)
    cfg.queueDepth = v
    cfg.queueDepthOrigin = "kwarg"
  of "slabCapacity":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("EventBroker kwarg 'slabCapacity' must be > 0, got " & $v, n)
    cfg.slabCapacity = v
    cfg.slabCapacityOrigin = "kwarg"
  of "maxPayloadBytes":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("EventBroker kwarg 'maxPayloadBytes' must be > 0, got " & $v, n)
    cfg.maxPayloadBytes = v
    cfg.maxPayloadBytesOrigin = "kwarg"
  of "maxDynamicPayloadBytes":
    let v = intValOrFail(n, kw)
    if v <= 0 or v > int(high(uint32)):
      error(
        "EventBroker kwarg 'maxDynamicPayloadBytes' must be in 1..high(uint32), got " &
          $v,
        n,
      )
    cfg.maxDynamicPayloadBytes = v
    cfg.maxDynamicPayloadBytesOrigin = "kwarg"
  of "freeListShards":
    let v = intValOrFail(n, kw)
    if v <= 0 or v > 64:
      error("EventBroker kwarg 'freeListShards' must be in 1..64, got " & $v, n)
    cfg.freeListShards = v
    cfg.freeListShardsOrigin = "kwarg"
  else:
    error(
      "Unknown EventBroker(mt) kwarg '" & kw & "'. Valid: " & ValidEvtKwargs.join(", "),
      n,
    )

proc presetFromKwargRhs(rhs: NimNode): BuiltinPreset =
  ## Extracts a built-in preset name from a kwarg RHS. Accepts identifier
  ## form (`preset = fastBurst`).
  if rhs.kind != nnkIdent:
    error(
      "preset value must be one of the built-in preset names " &
        "(defaultBalanced, fastBurst, largePayload, tinyFootprint), got " & $rhs.kind &
        " — " & rhs.repr,
      rhs,
    )
  parseBuiltinPreset($rhs, rhs)

proc parseMtEvtKwargs*(kwargs: openArray[NimNode]): MtEvtCfg =
  ## Parses kwarg nodes (everything between `mt` and the trailing body).
  ## Each node must be of shape `nnkExprEqExpr` (`name = value`).
  ##
  ## Order of application:
  ##   1. defaultMtEvtCfg()
  ##   2. `preset = <name>` if present (overrides defaults)
  ##   3. individual kwargs (override the preset)
  result = defaultMtEvtCfg()
  for n in kwargs:
    if n.kind != nnkExprEqExpr:
      error(
        "EventBroker(mt) expects kwargs of the form 'name = value', got " & $n.kind &
          " — " & n.repr,
        n,
      )
    let nameNode = n[0]
    if nameNode.kind != nnkIdent:
      error("EventBroker(mt) kwarg name must be an identifier", nameNode)
    if $nameNode == "preset":
      applyEvtPreset(result, presetFromKwargRhs(n[1]))
  for n in kwargs:
    let name = $n[0]
    if name == "preset":
      continue
    applyEvtKwarg(result, name, n[1])

# ---------------------------------------------------------------------------
# Kwarg parsing — RequestBroker(mt)
# ---------------------------------------------------------------------------

const ValidReqKwargs = [
  "queueDepth", "slabCapacity", "maxPayloadBytes", "maxDynamicPayloadBytes",
  "responseSlots", "maxResponseBytes", "freeListShards",
]

proc applyReqKwarg(cfg: var MtReqCfg, kw: string, n: NimNode) =
  case kw
  of "queueDepth":
    let v = intValOrFail(n, kw)
    if not isPow2(v):
      error("RequestBroker kwarg 'queueDepth' must be power-of-2, got " & $v, n)
    cfg.queueDepth = v
    cfg.queueDepthOrigin = "kwarg"
  of "slabCapacity":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'slabCapacity' must be > 0, got " & $v, n)
    cfg.slabCapacity = v
    cfg.slabCapacityOrigin = "kwarg"
  of "maxPayloadBytes":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'maxPayloadBytes' must be > 0, got " & $v, n)
    cfg.maxPayloadBytes = v
    cfg.maxPayloadBytesOrigin = "kwarg"
  of "maxDynamicPayloadBytes":
    let v = intValOrFail(n, kw)
    if v <= 0 or v > int(high(uint32)):
      error(
        "RequestBroker kwarg 'maxDynamicPayloadBytes' must be in 1..high(uint32), got " &
          $v,
        n,
      )
    cfg.maxDynamicPayloadBytes = v
    cfg.maxDynamicPayloadBytesOrigin = "kwarg"
  of "responseSlots":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'responseSlots' must be > 0, got " & $v, n)
    cfg.responseSlots = v
    cfg.responseSlotsOrigin = "kwarg"
  of "maxResponseBytes":
    let v = intValOrFail(n, kw)
    if v <= 0:
      error("RequestBroker kwarg 'maxResponseBytes' must be > 0, got " & $v, n)
    cfg.maxResponseBytes = v
    cfg.maxResponseBytesOrigin = "kwarg"
  of "freeListShards":
    let v = intValOrFail(n, kw)
    if v <= 0 or v > 64:
      error("RequestBroker kwarg 'freeListShards' must be in 1..64, got " & $v, n)
    cfg.freeListShards = v
    cfg.freeListShardsOrigin = "kwarg"
  else:
    error(
      "Unknown RequestBroker(mt) kwarg '" & kw & "'. Valid: " & ValidReqKwargs.join(
        ", "
      ),
      n,
    )

# ---------------------------------------------------------------------------
# Type-driven default sizing
# ---------------------------------------------------------------------------
#
# Walks a Nim type AST at macro time and recommends a cell payload size.
# Triggered when the user did NOT provide an explicit `maxPayloadBytes`
# / `maxResponseBytes` kwarg, AND a preset did not set those fields.
#
# Sizing table (matches doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md §8):
#
#   scalar (bool/intN/uintN/floatN/byte/char/enum/distinct of scalar)  64 B
#   string (or object whose largest field is string)                   4 KB
#   seq[string] / object containing seq[string]                        16 KB
#   seq[byte]  / object containing seq[byte]                           64 KB
#   anything else (alias / external type / unknown ident)              8 KB + warning

const
  ScalarBytes* = 64
  StringBytes* = 4 * 1024
  SeqStringBytes* = 16 * 1024
  SeqByteBytes* = 64 * 1024
  UnclassifiableBytes* = 8 * 1024

proc classifyTypeSize*(t: NimNode): tuple[bytes: int, reason: string] =
  ## Classifies a type AST into a recommended payload-cell size.
  ## Caller decides what to do with "unclassifiable" (typically: use
  ## the value + emit a warning so the user knows to override).
  if t.kind == nnkIdent:
    let name = $t
    case name
    of "bool", "char", "byte", "uint", "int", "uint8", "int8", "uint16", "int16",
        "uint32", "int32", "uint64", "int64", "float", "float32", "float64":
      (ScalarBytes, "scalar:" & name)
    of "string":
      (StringBytes, "string")
    else:
      # enum / distinct / alias / external object — can't tell at macro
      # time without resolving the symbol. Fall back to safe size.
      (UnclassifiableBytes, "unclassifiable:" & name)
  elif t.kind == nnkBracketExpr and t.len >= 2 and
      (t[0].kind == nnkIdent or t[0].kind == nnkDotExpr):
    # Accept both bare (`Option[T]`) and qualified
    # (`options.Option[T]`) outer names. For the dotted form we treat
    # the rightmost ident as the bracket name, while also retaining
    # the fully qualified form so the existing `options.Option` arm
    # below still matches when the user writes the full path.
    let outer =
      if t[0].kind == nnkIdent:
        $t[0]
      else:
        # nnkDotExpr: lhs.rhs — use rhs as the primary name.
        if t[0].len >= 2 and t[0][1].kind == nnkIdent:
          $t[0][1]
        else:
          t[0].repr
    if outer == "seq":
      let inner = t[1]
      if inner.kind == nnkIdent:
        let n = $inner
        if n == "byte" or n == "uint8":
          (SeqByteBytes, "seq[byte]")
        elif n == "string":
          (SeqStringBytes, "seq[string]")
        else:
          # seq[<other>] — assume short list of small items.
          (StringBytes, "seq[" & n & "]")
      else:
        (UnclassifiableBytes, "unclassifiable:" & t.repr)
    elif outer == "array":
      # array[N, T] — bounded; treat as the underlying T classification.
      if t.len >= 3:
        classifyTypeSize(t[2])
      else:
        (UnclassifiableBytes, "unclassifiable:" & t.repr)
    elif outer == "Option":
      # Option[T] — wire size is bounded by T plus a one-byte CBOR
      # tag (null marker vs concrete value). Recurse into the inner
      # type and reuse its classification verbatim; the +1 byte sits
      # comfortably inside whatever bucket T lands in. Without this
      # special case Option[seq[byte]] would silently under-allocate
      # (8 KB fallback < 64 KB seq[byte]), while Option[int64] would
      # noisily over-allocate at 8 KB.
      let inner = classifyTypeSize(t[1])
      (inner.bytes, "Option[" & inner.reason & "]")
    else:
      (UnclassifiableBytes, "unclassifiable:" & outer)
  else:
    (UnclassifiableBytes, "unclassifiable:" & $t.kind)

proc classifyFieldsMax*(
    fieldTypes: openArray[NimNode]
): tuple[bytes: int, reason: string] =
  ## Returns the maximum-size classification across a collection of
  ## field-type ASTs. Used to size the cell for an inline object.
  var bestBytes = ScalarBytes
  var bestReason = "scalar"
  for ft in fieldTypes:
    let c = classifyTypeSize(ft)
    if c.bytes > bestBytes:
      bestBytes = c.bytes
      bestReason = c.reason
  (bestBytes, bestReason)

proc peelFutureResult*(t: NimNode): NimNode =
  ## Walks `Future[Result[T, E]]` and returns T. Returns nil if the
  ## shape doesn't match.
  var cur = t
  if cur.kind == nnkBracketExpr and cur.len >= 2 and cur[0].kind == nnkIdent and
      $cur[0] == "Future":
    cur = cur[1]
  if cur.kind == nnkBracketExpr and cur.len >= 2 and cur[0].kind == nnkIdent and
      ($cur[0] == "Result" or $cur[0] == "results.Result"):
    return cur[1]
  nil

  # ---------------------------------------------------------------------------
  # Compile-time summary formatting
  # ---------------------------------------------------------------------------

proc fmtBytes(n: int): string =
  if n >= 1024 * 1024:
    $(n div (1024 * 1024)) & "." &
      align($((n mod (1024 * 1024)) div (102 * 1024)), 1, '0') & " MB"
  elif n >= 1024:
    $(n div 1024) & "." & align($((n mod 1024) div 102), 1, '0') & " KB"
  else:
    $n & " B"

# Approximate per-element bytes — match the runtime layouts in mt_queue.nim.
# Exact figures don't matter; this is a sizing-guidance number for the user.
const
  RingSlotBytes = 24 # Slot[uint32] = idx u32 + seq u64 + pad
  CellHeaderBytes = 32 # CellHeader (refcount, length, prev/next idx)
  RespSlotHeaderBytes = 48 # ResponseSlot header

proc alignUp8(n: int): int {.inline.} =
  (n + 7) and (not 7)

proc estEvtIdleBytes(cfg: MtEvtCfg): tuple[ring, slab, total: int] =
  let ring = cfg.queueDepth * RingSlotBytes
  let cellStride = alignUp8(CellHeaderBytes + cfg.maxPayloadBytes)
  let slab = cfg.slabCapacity * cellStride
  (ring, slab, ring + slab)

proc estReqIdleBytes(cfg: MtReqCfg): tuple[ring, slab, respPool, total: int] =
  let ring = cfg.queueDepth * RingSlotBytes
  let cellStride = alignUp8(CellHeaderBytes + cfg.maxPayloadBytes)
  let slab = cfg.slabCapacity * cellStride
  let slotStride = alignUp8(RespSlotHeaderBytes + cfg.maxResponseBytes)
  let respPool = cfg.responseSlots * slotStride
  (ring, slab, respPool, ring + slab + respPool)

proc fmtEvtCfgSummary*(typeName: string, cfg: MtEvtCfg): string =
  let est = estEvtIdleBytes(cfg)
  "[brokers] EventBroker(" & typeName & "): " & "queueDepth=" & $cfg.queueDepth & " [" &
    cfg.queueDepthOrigin & "], " & "slabCapacity=" & $cfg.slabCapacity & " [" &
    cfg.slabCapacityOrigin & "], " & "maxPayloadBytes=" & $cfg.maxPayloadBytes & " [" &
    cfg.maxPayloadBytesOrigin & "], freeListShards=" & $cfg.freeListShards & " [" &
    cfg.freeListShardsOrigin & "] — idle RAM: ring≈" & fmtBytes(est.ring) &
    ", slab≈" & fmtBytes(est.slab) & ", total≈" & fmtBytes(est.total)

proc fmtReqCfgSummary*(typeName: string, cfg: MtReqCfg): string =
  let est = estReqIdleBytes(cfg)
  "[brokers] RequestBroker(" & typeName & "): " & "queueDepth=" & $cfg.queueDepth & " [" &
    cfg.queueDepthOrigin & "], " & "slabCapacity=" & $cfg.slabCapacity & " [" &
    cfg.slabCapacityOrigin & "], " & "maxPayloadBytes=" & $cfg.maxPayloadBytes & " [" &
    cfg.maxPayloadBytesOrigin & "], responseSlots=" & $cfg.responseSlots & " [" &
    cfg.responseSlotsOrigin & "], maxResponseBytes=" & $cfg.maxResponseBytes & " [" &
    cfg.maxResponseBytesOrigin & "], freeListShards=" & $cfg.freeListShards & " [" &
    cfg.freeListShardsOrigin & "] — idle RAM: ring≈" & fmtBytes(est.ring) &
    ", slab≈" & fmtBytes(est.slab) & ", respPool≈" & fmtBytes(est.respPool) &
    ", total≈" & fmtBytes(est.total)

proc parseMtReqKwargs*(kwargs: openArray[NimNode]): MtReqCfg =
  ## See `parseMtEvtKwargs` for order-of-application rules.
  result = defaultMtReqCfg()
  for n in kwargs:
    if n.kind != nnkExprEqExpr:
      error(
        "RequestBroker(mt) expects kwargs of the form 'name = value', got " & $n.kind &
          " — " & n.repr,
        n,
      )
    let nameNode = n[0]
    if nameNode.kind != nnkIdent:
      error("RequestBroker(mt) kwarg name must be an identifier", nameNode)
    if $nameNode == "preset":
      applyReqPreset(result, presetFromKwargRhs(n[1]))
  for n in kwargs:
    let name = $n[0]
    if name == "preset":
      continue
    applyReqKwarg(result, name, n[1])

# ---------------------------------------------------------------------------
# Splitting varargs into kwargs + body
# ---------------------------------------------------------------------------

proc splitMtArgs*(
    args: NimNode, what: string
): tuple[kwargs: seq[NimNode], body: NimNode] =
  ## Splits a `varargs[untyped]` macro arg list into (kwarg nodes, body
  ## stmt-list). The body is always the last element. Errors if no body.
  if args.len == 0:
    error(what & " requires a body block", args)
  let bodyNode = args[args.len - 1]
  if bodyNode.kind notin {nnkStmtList, nnkTypeDef, nnkTypeSection}:
    error(
      what & " body must be a `:` block of type definitions (got " & $bodyNode.kind & ")",
      bodyNode,
    )
  var kw = newSeqOfCap[NimNode](args.len - 1)
  for i in 0 ..< args.len - 1:
    kw.add(args[i])
  (kw, bodyNode)

{.pop.} # warning[UnreachableCode]
{.pop.} # raises: []
