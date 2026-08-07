## api_cbor_tuple
## ---------------
## Map-shaped CBOR encoders/decoders for named Nim tuple aliases used
## across the FFI boundary.
##
## ## Why this exists
##
## `cbor_serialization` 0.3.0 emits Nim tuples as positional CBOR arrays
## (`writer.nim:423` — `proc write*[T: tuple]`) and decodes them
## symmetrically (`reader_impl.nim:144` — `proc read*[T: tuple]`).
## Wrapper-side codegen (Cpp / Py / Rust / Go) emits a tuple alias as
## a struct with NAMED fields and expects a CBOR map keyed by those
## names. Without alignment, a wrapper round-trip of `seq[TupleRow]`
## fails with "invalid type: sequence, expected map".
##
## This module provides a macro `bindCborTupleMap(T)` that emits a
## per-tuple `write` / `read` overload bound to the `BrokerCbor` flavor.
## The overloads encode/consume a CBOR map keyed by the Nim field
## names. Resolver code calls the macro for every named tuple alias
## that's auto-registered as part of the FFI surface.
##
## ## Limitation
##
## Only NAMED tuple aliases are supported (e.g.
## `type TupleRow = tuple[key: string, payload: string]`). Unnamed
## positional tuples (`tuple[int32, string]`) keep the library default
## (positional CBOR array) — wrappers receive synthesised field names
## (`first`, `second`, ...) on the struct side which would not match
## a positional CBOR shape; the tuple-as-struct codegen rejects > 9
## positional elements anyway, so no wrapper currently emits structs
## from unnamed tuples.

{.push raises: [].}

import std/macros
import cbor_serialization
import cbor_serialization/[reader_impl, writer]

import ./api_cbor_codec

export api_cbor_codec

macro bindCborTupleMap*(T: typed): untyped =
  ## Emit `write` and `read` overloads for tuple type `T` that use the
  ## CBOR map shape (field name → value) instead of the default
  ## positional CBOR array. The overloads bind to `BrokerCbor.Writer` /
  ## `BrokerCbor.Reader` so they take precedence over the generic
  ## `write[T: tuple]` / `read[T: tuple]` from cbor_serialization.
  let typeIdent = T
  let writerSym = bindSym("CborWriter")
  let readerSym = bindSym("CborReader")
  let valueIdent = ident("value")
  let writerIdent = ident("w")
  let readerIdent = ident("r")
  let keyIdent = ident("key")

  # Field names are extracted at proc body-instantiation time via
  # `fieldPairs`, so the macro only needs to emit the proc skeletons —
  # the proc body iterates the type's fields generically.
  result = quote:
    proc write*(
        `writerIdent`: var `writerSym`, `valueIdent`: `typeIdent`
    ) {.raises: [IOError].} =
      var fieldsCount = 0
      for _, _ in fieldPairs(`valueIdent`):
        inc fieldsCount
      `writerIdent`.beginObject(fieldsCount)
      for fieldName, fieldValue in fieldPairs(`valueIdent`):
        `writerIdent`.writeField(fieldName, fieldValue)
      `writerIdent`.endObject(stopCode = false)

    proc read*(
        `readerIdent`: var `readerSym`, `valueIdent`: var `typeIdent`
    ) {.raises: [SerializationError, IOError].} =
      mixin readValue
      `readerIdent`.parseObject(`keyIdent`):
        var matched = false
        for fieldName, fieldValue in fieldPairs(`valueIdent`):
          if not matched and fieldName == `keyIdent`:
            `readerIdent`.readValue(fieldValue)
            matched = true
        if not matched:
          `readerIdent`.skipSingleValue()

{.pop.}
