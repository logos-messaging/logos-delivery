## API CBOR Codec
## ---------------
## CBOR encode/decode primitives for the CBOR FFI strategy.
##
## This module owns the `BrokerCbor` flavor (configured with strict-but-
## forward-compat settings), the `CborResponseEnvelope[T]` wire type that
## represents `Result[T, string]` on the wire, and the encode/decode helpers
## that wrap `nim-cbor-serialization`'s exception-raising API as
## `Result`-returning procs suitable for `raises: []` call sites.
##
## Design choices (see plan §4):
## - Response envelope is a CBOR map with two optional fields:
##     `{ "ok": T }` for success, `{ "err": tstr }` for failure.
##   The map form lets us extend the schema without breaking older wrappers.
## - Void responses use the `CborUnit` zero-field marker so the generic
##   `CborResponseEnvelope[T]` type also covers `Result[void, string]`.
## - Encoding never raises — failures are surfaced as `Result.err`. Caller
##   threads (often foreign threads via the FFI gate) cannot meaningfully
##   handle a Nim `IOError` so all serialization exceptions are caught and
##   stringified at this layer.
##
## All buffers exchanged with the FFI boundary live elsewhere
## (`api_common`'s shared-heap helpers); this module deals only in
## `seq[byte]` / `openArray[byte]`.

{.push raises: [].}

import std/[options, typetraits]
import results
import cbor_serialization
import cbor_serialization/[reader_impl, writer]
import cbor_serialization/std/options as cbor_options

export results, cbor_serialization, cbor_options

# ---------------------------------------------------------------------------
# Flavor
# ---------------------------------------------------------------------------

createCborFlavor(
  BrokerCbor,
  automaticObjectSerialization = true,
  automaticPrimitivesSerialization = true,
  requireAllFields = true,
    # Provider-side decode rejects malformed requests up front rather than
    # silently zero-initialising missing fields.
  omitOptionalFields = true, # Compactness: only populated Options hit the wire.
  allowUnknownFields = true,
    # Wrappers built against a newer schema can still talk to an older Nim
    # library — unknown fields are dropped on decode rather than failing.
  skipNullFields = false,
)

# Encode enums as numeric ordinals so the wire format matches what
# Python's IntEnum and C++'s underlying enum class produce naturally.
# Without this override the upstream default is `EnumAsString`, which
# decodes fine on the Nim side but diverges from foreign-language
# wrappers that send enum values as ints.
enumRep(Cbor, BrokerCbor, EnumRepresentation.EnumAsNumber)

# ---------------------------------------------------------------------------
# Distinct-type bridging
#
# nim-cbor-serialization 0.3.0 ships a generic writer for distinct types
# (`proc write*[T: distinct]` in writer.nim) but the matching reader is
# commented out upstream. We provide both halves here:
# - a generic `read[T: distinct]` that decodes into the underlying type
#   and casts back, mirroring the writer's behaviour.
# - the flavor-level `defaultReader(distinct)` / `defaultWriter(distinct)`
#   bindings so user-defined distinct types work out of the box on the
#   `BrokerCbor` flavor without per-type registration boilerplate.
# ---------------------------------------------------------------------------

proc read*[T: distinct](
    r: var CborReader, value: var T
) {.raises: [SerializationError, IOError].} =
  mixin readValue
  var underlying: distinctBase(T, recursive = false)
  readValue(r, underlying)
  value = T(underlying)

BrokerCbor.defaultReader(distinct)
  # Writer side is already bound by `defaultPrimitiveWriter` (see
  # cbor_serialization/format.nim:99). Re-binding here causes
  # `ambiguous call writeValue` at user call sites.

# Enum reader override.
#
# With `enumRep = EnumAsNumber` (set above) the writer emits enum values
# as CBOR Unsigned ints, matching what Python's `IntEnum` and C++'s
# `enum class` underlying values produce on the wire. The upstream
# `read[T: enum]` only accepts CBOR strings (its private `parseEnum`
# helper hard-codes `allowNumericRepr = false`), so we provide a
# numeric-aware override at the flavor level: read an int via the
# already-bound `read[T: SomeInteger]`, range-check against the enum's
# low/high ordinals, then cast.
proc readValue*[T: enum](
    r: var (BrokerCbor.Reader), value: var T
) {.raises: [IOError, SerializationError].} =
  mixin read
  var i: int
  read(r, i)
  if i < ord(T.low) or i > ord(T.high):
    raise
      newException(CborReaderError, "CBOR enum value " & $i & " out of range for " & $T)
  value = T(i)

# ---------------------------------------------------------------------------
# Wire types
# ---------------------------------------------------------------------------

type CborUnit* = object
  ## Empty marker used as the payload of `Result[void, string]` envelopes.
  ## Encodes as a zero-field CBOR map (`{}`).

type CborResponseEnvelope*[T] = object
  ## Wire representation of `Result[T, string]`.
  ##
  ## With the BrokerCbor flavor (`omitOptionalFields = true`), exactly one
  ## of `ok` and `err` is populated on a well-formed envelope. Decode
  ## validates this in `fromEnvelope`.
  ok*: Option[T]
  err*: Option[string]

# ---------------------------------------------------------------------------
# Result <-> Envelope
# ---------------------------------------------------------------------------

proc toEnvelope*[T](r: Result[T, string]): CborResponseEnvelope[T] =
  if r.isOk():
    CborResponseEnvelope[T](ok: some(r.value), err: none(string))
  else:
    CborResponseEnvelope[T](ok: none(T), err: some(r.error))

proc fromEnvelope*[T](e: CborResponseEnvelope[T]): Result[T, string] {.raises: [].} =
  if e.ok.isSome() and e.err.isSome():
    return Result[T, string].err(
      "malformed CBOR response envelope: both 'ok' and 'err' present"
    )
  if e.ok.isSome():
    return Result[T, string].ok(e.ok.get())
  if e.err.isSome():
    return Result[T, string].err(e.err.get())
  Result[T, string].err(
    "malformed CBOR response envelope: neither 'ok' nor 'err' present"
  )

# ---------------------------------------------------------------------------
# Encode / Decode helpers
# ---------------------------------------------------------------------------

template cborEncode*[T](value: T): Result[seq[byte], string] =
  ## Encode `value` to CBOR using the BrokerCbor flavor. Wraps every encode
  ## failure as `Result.err`; never raises.
  ##
  ## Implemented as a template so that `BrokerCbor`'s flavor-bound templates
  ## (`init`, `writeValue`, `PreferredOutputType`) resolve at the user's
  ## call site rather than inside a generic proc — the latter loses access
  ## to the flavor's auto-generated object writers.
  block:
    var encRes: Result[seq[byte], string]
    try:
      let buf = BrokerCbor.encode(value)
      encRes = Result[seq[byte], string].ok(buf)
    except SerializationError as exc:
      encRes = Result[seq[byte], string].err("cbor encode failed: " & exc.msg)
    except IOError as exc:
      encRes = Result[seq[byte], string].err("cbor encode IO failure: " & exc.msg)
    except CatchableError as exc:
      encRes =
        Result[seq[byte], string].err("cbor encode unexpected failure: " & exc.msg)
    encRes

template cborEncodeShared*[T](
    value: T, bufOut: var pointer, lenOut: var int
): Result[void, string] =
  ## Refc-safe variant of `cborEncode`: produces an `allocShared0`-owned
  ## buffer and never lets the intermediate `seq[byte]` escape across thread
  ## boundaries.
  ##
  ## On `ok` the caller owns `bufOut` (size `lenOut` bytes) and must
  ## `deallocShared(bufOut)` once done. On empty input `bufOut` is `nil` and
  ## `lenOut` is 0. Used by the CBOR FFI listener path: under `--mm:refc` a
  ## `seq[byte]` produced on the delivery thread cannot be safely shared with
  ## subscriber callbacks invoked synchronously, so we copy the bytes into
  ## shared heap immediately and drop the seq.
  ##
  ## Same template-vs-generic-proc rationale as `cborEncode`.
  block:
    bufOut = nil
    lenOut = 0
    var encShRes: Result[void, string]
    try:
      let buf = BrokerCbor.encode(value)
      if buf.len > 0:
        let p = allocShared0(buf.len)
        copyMem(p, unsafeAddr buf[0], buf.len)
        bufOut = p
        lenOut = buf.len
      encShRes = Result[void, string].ok()
    except SerializationError as exc:
      encShRes = Result[void, string].err("cbor encode failed: " & exc.msg)
    except IOError as exc:
      encShRes = Result[void, string].err("cbor encode IO failure: " & exc.msg)
    except CatchableError as exc:
      encShRes = Result[void, string].err("cbor encode unexpected failure: " & exc.msg)
    encShRes

template cborDecode*[T](buf: openArray[byte], _: typedesc[T]): Result[T, string] =
  ## Decode a CBOR-encoded buffer into `T` using the BrokerCbor flavor.
  ## Wraps every decode failure as `Result.err`; never raises. Same
  ## template-vs-generic-proc rationale as `cborEncode`.
  block:
    var decRes: Result[T, string]
    try:
      let v = BrokerCbor.decode(buf, T)
      decRes = Result[T, string].ok(v)
    except SerializationError as exc:
      decRes = Result[T, string].err("cbor decode failed: " & exc.msg)
    except IOError as exc:
      decRes = Result[T, string].err("cbor decode IO failure: " & exc.msg)
    except CatchableError as exc:
      decRes = Result[T, string].err("cbor decode unexpected failure: " & exc.msg)
    decRes

# ---------------------------------------------------------------------------
# Result envelope shortcuts
# ---------------------------------------------------------------------------

template cborEncodeResultEnvelope*[T](r: Result[T, string]): Result[seq[byte], string] =
  ## Encode `Result[T, string]` as a CBOR response envelope.
  cborEncode(toEnvelope(r))

template cborDecodeResultEnvelope*[T](
    buf: openArray[byte], _: typedesc[T]
): Result[T, string] =
  ## Decode a CBOR response envelope into `Result[T, string]`.
  ##
  ## Returns the inner `Result` on success, or a framework error string
  ## (prefixed `cbor decode failed: ...`) on a CBOR-level failure.
  block:
    let envRes = cborDecode(buf, CborResponseEnvelope[T])
    var res: Result[T, string]
    if envRes.isErr():
      res = Result[T, string].err(envRes.error)
    else:
      res = fromEnvelope(envRes.value)
    res

{.pop.}
