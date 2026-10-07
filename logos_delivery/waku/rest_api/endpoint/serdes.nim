{.push raises: [].}

import
  std/[typetraits, parseutils],
  results,
  stew/[byteutils, base10],
  chronicles,
  serialization,
  json_serialization,
  json_serialization/pkg/results,
  json_serialization/std/net,
  json_serialization/std/sets,
  presto/common
import ../../common/base64

logScope:
  topics = "waku node rest"

createJsonFlavor RestJson

Json.setWriter JsonWriter, PreferredOutput = string

template skipUnrecognizedField*(reader: var JsonReader, field: typed) =
  ## Consumes the value of an unknown field, so decoding can go on to the next one.
  debug "skipping unrecognized JSON field",
    fieldName, typeName = typetraits.name(typeof field)
  reader.skipSingleJsValue()

type SerdesResult*[T] = Result[T, cstring]

proc writeValue*(
    writer: var JsonWriter, value: Base64String
) {.gcsafe, raises: [IOError].} =
  writer.writeValue(string(value))

proc readValue*(
    reader: var JsonReader, value: var Base64String
) {.gcsafe, raises: [SerializationError, IOError].} =
  value = Base64String(reader.readValue(string))

proc deserializeError(): string =
  ## To be called from the except branch. formatMsg is a method, which the
  ## compile-time VM cannot call.
  when nimvm:
    "Unable to deserialize data"
  else:
    let exc = (ref SerializationError)(getCurrentException())
    "Unable to deserialize data: " & exc.formatMsg("body")

proc decodeFromJsonString*[T](
    t: typedesc[T], data: JsonString, requireAllFields: bool = true
): SerdesResult[T] =
  try:
    if requireAllFields:
      ok(
        RestJson.decode(
          string(data), T, requireAllFields = true, allowUnknownFields = true
        )
      )
    else:
      ok(
        RestJson.decode(
          string(data), T, requireAllFields = false, allowUnknownFields = true
        )
      )
  except SerializationError:
    # TODO: Do better error reporting here
    err("Unable to deserialize data")

proc decodeJsonBytesWithReason*[T](
    t: typedesc[T], data: openArray[byte], requireAllFields: bool = true
): Result[T, string] =
  ## Same as decodeFromJsonBytes, but the error carries the decoder's reason.
  try:
    return ok(
      RestJson.decode(
        string.fromBytes(data),
        T,
        requireAllFields = requireAllFields,
        allowUnknownFields = true,
      )
    )
  except SerializationError:
    return err(deserializeError())

# Internal static implementation
proc decodeFromJsonBytes*[T](
    t: typedesc[T], data: openArray[byte], requireAllFields: bool = true
): SerdesResult[T] =
  let decoded = decodeJsonBytesWithReason(T, data, requireAllFields).valueOr:
    return err("Unable to deserialize data")

  return ok(decoded)

proc encodeIntoJsonString*(value: auto): SerdesResult[string] =
  var encoded: string
  try:
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.writeValue(value)
    encoded = stream.getOutput(string)
  except SerializationError, IOError:
    # TODO: Do better error reporting here
    return err("unable to serialize data")

  ok(encoded)

proc encodeIntoJsonBytes*(value: auto): SerdesResult[seq[byte]] =
  var encoded: seq[byte]
  try:
    var stream = memoryOutput()
    var writer = JsonWriter[RestJson].init(stream)
    writer.writeValue(value)
    encoded = stream.getOutput(seq[byte])
  except SerializationError, IOError:
    # TODO: Do better error reporting here
    return err("unable to serialize data")

  ok(encoded)

#### helpers

proc encodeString*(value: string): SerdesResult[string] =
  ok(value)

proc decodeString*(t: typedesc[string], value: string): SerdesResult[string] =
  ok(value)

proc encodeString*(value: SomeUnsignedInt): SerdesResult[string] =
  ok(Base10.toString(value))

proc decodeString*(T: typedesc[SomeUnsignedInt], value: string): SerdesResult[T] =
  return Base10.decode(T, value)
