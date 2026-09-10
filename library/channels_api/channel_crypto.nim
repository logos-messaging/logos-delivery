## Adapts the C cipher callbacks to the `ChannelCryptoFn` closures the
## channel layer stores.
##
## They cross the boundary as `uint64` because nim-ffi cannot yet express a
## host-implemented interface for an `abi = c` library. Once reverse FFI
## grows `abi = c` support this whole module goes away, and the cipher stops
## blocking the event loop as a bonus:
## https://github.com/logos-messaging/nim-ffi/issues/153

{.push raises: [].}

import chronos, results
import logos_delivery

type LogosDeliveryCryptoFn* = proc(
  userData: pointer,
  input: ptr byte,
  inputLen: csize_t,
  output: ptr ptr byte,
  outputLen: ptr csize_t,
): cint {.cdecl, gcsafe, raises: [].}
  ## Bytes in, bytes out: the cipher points `output`/`outputLen` at its
  ## result and returns 0, or non-zero to fail the message. We copy the
  ## result on return, so the buffer need only outlive the call.
  ##
  ## Full contract in `library/liblogosdelivery.h`.

proc toChannelCryptoFn*(
    fnHandle: uint64, userData: uint64
): Result[ChannelCryptoFn, string] =
  if fnHandle == 0:
    return err("callback pointer is null")
  if uint64(cast[uint](fnHandle)) != fnHandle:
    return err("callback pointer does not fit this platform's pointer width")
  if uint64(cast[uint](userData)) != userData:
    return err("userData does not fit this platform's pointer width")

  let fn = cast[LogosDeliveryCryptoFn](cast[uint](fnHandle))
  let ctx = cast[pointer](cast[uint](userData))

  proc callCipher(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    let input =
      if payload.len == 0:
        nil
      else:
        cast[ptr byte](unsafeAddr payload[0])

    var
      output: ptr byte = nil
      outputLen: csize_t = 0

    let rc = fn(ctx, input, csize_t(payload.len), addr output, addr outputLen)
    if rc != 0:
      return err("channel crypto callback failed with code " & $rc)

    let n = int(outputLen)
    if n < 0:
      return err("channel crypto callback returned an out-of-range length")
    if n > 0 and output.isNil():
      ## Copying from here would segfault, and treating it as empty would
      ## put a zero-length payload on the wire.
      return err("channel crypto callback returned a null buffer of non-zero length")
    if n == 0 and payload.len > 0:
      return err("channel crypto callback returned nothing for a non-empty input")

    var res = newSeq[byte](n)
    if n > 0:
      copyMem(addr res[0], output, n)
    return ok(res)

  return ok(callCipher)

proc toChannelCrypto*(
    encryptFn: uint64, decryptFn: uint64, userData: uint64
): Result[Opt[ChannelCrypto], string] =
  ## Both callbacks zero means the channel is not encrypted; `userData` is
  ## meaningless on its own, so it does not take part in the decision.
  if encryptFn == 0 and decryptFn == 0:
    return ok(Opt.none(ChannelCrypto))

  let encrypt = ?toChannelCryptoFn(encryptFn, userData)
  let decrypt = ?toChannelCryptoFn(decryptFn, userData)
  return ok(Opt.some(?ChannelCrypto.init(encrypt, decrypt)))

{.pop.}
