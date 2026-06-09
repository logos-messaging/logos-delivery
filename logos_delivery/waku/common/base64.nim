{.push raises: [].}

import stew/[byteutils, base64], results

type Base64String* = distinct string

proc encode*[T: byte | char](value: openArray[T]): Base64String =
  Base64String(encode(Base64Pad, value))

proc encode*(value: string): Base64String =
  encode(toBytes(value))

proc decode[T: byte | char](
    btype: typedesc[Base64Types], instr: openArray[T]
): Result[seq[byte], string] =
  ## Decode BASE64 string ``instr`` and return sequence of bytes as result.
  if len(instr) == 0:
    return ok(newSeq[byte]())

  var bufferLen = decodedLength(btype, len(instr))
  var buffer = newSeq[byte](bufferLen)

  if decode(btype, instr, buffer, bufferLen) != Base64Status.Success:
    return err("Incorrect base64 string")

  buffer.setLen(bufferLen)
  ok(buffer)

proc decode*(t: Base64String): Result[seq[byte], string] =
  decode(Base64Pad, string(t))

proc `$`*(t: Base64String): string {.inline.} =
  string(t)

proc `==`*(lhs: Base64String | string, rhs: Base64String | string): bool {.inline.} =
  string(lhs) == string(rhs)
