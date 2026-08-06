## array[N, byte] serialized as a length-delimited bytes field.

{.push raises: [].}

import faststreams
import protobuf_serialization
import protobuf_serialization/pkg/results
import protobuf_serialization/std/enums

export protobuf_serialization, results, enums

func supportsPacked*[N: static int](
    T: type array[N, byte], ProtoType: type ProtobufExt
): bool =
  false

func computeFieldSize*[N: static int](
    field: int,
    value: array[N, byte],
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  computeFieldSize(field, @value, pbytes, skipDefault)

proc writeField*[N: static int](
    stream: OutputStream,
    field: int,
    value: array[N, byte],
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, @value, pbytes, skipDefault)

proc readFieldInto*[N: static int](
    stream: InputStream,
    value: var array[N, byte],
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var s: seq[byte]
  if readFieldInto(stream, s, header, pbytes):
    if s.len == N:
      for i in 0 ..< N:
        value[i] = s[i]
      true
    else:
      false
  else:
    false
