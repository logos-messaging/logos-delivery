## No-op encryption providers. Install these when the application does
## not want actual encryption so the `Encrypt` / `Decrypt` brokers have
## something to dispatch to.

import results
import chronos
import ./encryption

proc setNoopEncryption*() =
  discard Encrypt.setProvider(
    proc(payload: seq[byte]): Future[Result[Encrypt, string]] {.async.} =
      return ok(Encrypt(payload))
  )

  discard Decrypt.setProvider(
    proc(payload: seq[byte]): Future[Result[Decrypt, string]] {.async.} =
      return ok(Decrypt(payload))
  )
