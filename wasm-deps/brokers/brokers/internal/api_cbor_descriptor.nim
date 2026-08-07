## Runtime schema-descriptor types for the CBOR FFI discovery API.
##
## `<lib>_listApis` and `<lib>_getSchema` return JSON-encoded views of these
## records so dynamic clients can introspect a library's surface without
## referring to the build-time generated headers.
##
## These types are hand-rolled (not produced by the broker macros) and are
## therefore part of the *stable* CBOR FFI v1 contract: changes to fields
## here are wire-breaking. Add new fields rather than rename / reorder.

{.push raises: [].}

import std/[json, options]
import ./api_cbor_codec

export api_cbor_codec

type
  ApiFieldInfo* = object
    name*: string
    nimType*: string

  ApiEnumValueInfo* = object
    name*: string
    ordinal*: int

  ApiTypeInfo* = object
    name*: string
    kind*: string ## "object" / "enum" / "alias" / "distinct"; matches `ApiTypeKind`.
    fields*: seq[ApiFieldInfo]
    enumValues*: seq[ApiEnumValueInfo]
    underlyingType*: string

  ApiRequestInfo* = object
    apiName*: string
    argsType*: string
      ## Nim type name of the synthesised args struct;
      ## empty string for zero-arg requests.
    argFields*: seq[ApiFieldInfo]
    responseType*: string

  ApiEventInfo* = object
    apiName*: string
    payloadType*: string

  ApiList* = object ## Lightweight payload returned by `<lib>_listApis`.
    libName*: string
    requests*: seq[string]
    events*: seq[string]

  LibraryDescriptor* = object ## Full payload returned by `<lib>_getSchema`.
    libName*: string
    cddl*: string ## Verbatim contents of the generated `<lib>.cddl`.
    requests*: seq[ApiRequestInfo]
    events*: seq[ApiEventInfo]
    types*: seq[ApiTypeInfo]

{.pop.}

# JSON serialisation lives outside `{.push raises: [].}` because std/json
# indexing can raise KeyError.

proc toJson*(f: ApiFieldInfo): JsonNode =
  %*{"name": f.name, "nimType": f.nimType}

proc toJson*(v: ApiEnumValueInfo): JsonNode =
  %*{"name": v.name, "ordinal": v.ordinal}

proc toJson*(t: ApiTypeInfo): JsonNode =
  result = %*{
    "name": t.name,
    "kind": t.kind,
    "fields": newJArray(),
    "enumValues": newJArray(),
    "underlyingType": t.underlyingType,
  }
  for f in t.fields:
    result["fields"].add(f.toJson())
  for v in t.enumValues:
    result["enumValues"].add(v.toJson())

proc toJson*(r: ApiRequestInfo): JsonNode =
  result = %*{
    "apiName": r.apiName,
    "argsType": r.argsType,
    "argFields": newJArray(),
    "responseType": r.responseType,
  }
  for f in r.argFields:
    result["argFields"].add(f.toJson())

proc toJson*(e: ApiEventInfo): JsonNode =
  %*{"apiName": e.apiName, "payloadType": e.payloadType}

proc toJson*(a: ApiList): JsonNode =
  %*{"libName": a.libName, "requests": a.requests, "events": a.events}

proc toJson*(d: LibraryDescriptor): JsonNode =
  result = %*{
    "libName": d.libName,
    "cddl": d.cddl,
    "requests": newJArray(),
    "events": newJArray(),
    "types": newJArray(),
  }
  for r in d.requests:
    result["requests"].add(r.toJson())
  for e in d.events:
    result["events"].add(e.toJson())
  for t in d.types:
    result["types"].add(t.toJson())

proc toJsonString*(a: ApiList): string =
  $a.toJson()

proc toJsonString*(d: LibraryDescriptor): string =
  $d.toJson()
