import std/[times, random], bearssl/rand, libp2p/crypto/crypto

## Randomization

proc randomize*() =
  ## Initializes the default random number generator with the given seed.
  ## From: https://nim-lang.org/docs/random.html#randomize,int64
  let now = getTime()
  randomize(now.toUnix() * 1_000_000_000 + now.nanosecond)

## RNG
# Copied from here: https://github.com/status-im/nim-libp2p/blob/d522537b19a532bc4af94fcd146f779c1f23bad0/tests/helpers.nim#L28

type Rng = object
  rng: ref HmacDrbgContext

# Typically having a module variable is considered bad design. This case should
# be considered as an exception and it should be used only in the tests.
var rngVar: Rng

proc getRng(): ref HmacDrbgContext =
  # TODO: if `rngVar` is a threadvar like it should be, there are random and
  #      spurious compile failures on mac - this is not gcsafe but for the
  #      purpose of the tests, it's ok as long as we only use a single thread
  {.gcsafe.}:
    if rngVar.rng.isNil():
      # libp2p v2.0.0: crypto.newRng() returns the new `Rng` wrapper type;
      # construct an HmacDrbgContext directly so the field type stays as
      # `ref HmacDrbgContext` (what bearssl-style consumers expect).
      rngVar.rng = HmacDrbgContext.new()

    rngVar.rng

template rng*(): ref HmacDrbgContext =
  getRng()

## Random byte sequences
# Copied from waku/waku_noise/noise_utils.randomSeqByte to break the test
# build's dependency on waku_noise (orphan code that is not part of any
# production code path; only the keystore + relay-RLN tests reused this
# helper for generating random secrets).
proc randomSeqByte*(rng: var HmacDrbgContext, size: int): seq[byte] =
  var output = newSeq[byte](size.uint32)
  hmacDrbgGenerate(rng, output)
  return output
