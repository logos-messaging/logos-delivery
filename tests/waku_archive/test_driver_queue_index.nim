{.used.}

import std/random, testutils/unittests
import logos_delivery/waku/waku_core, logos_delivery/waku/waku_archive/driver/queue_driver/index

var rng = initRand()

## Helpers

proc randomHash(): WakuMessageHash =
  var hash: WakuMessageHash

  for i in 0 ..< hash.len:
    let numb: byte = byte(rng.next())
    hash[i] = numb

  hash

suite "Queue Driver - index":
  ## Test vars
  let
    hash = randomHash()
    eqIndex1 = Index(time: getNanosecondTime(54321), hash: hash)
    eqIndex2 = Index(time: getNanosecondTime(54321), hash: hash)
    eqIndex3 = Index(time: getNanosecondTime(54321), hash: randomHash())
    eqIndex4 = Index(time: getNanosecondTime(65432), hash: hash)

  test "Index comparison":
    check:
      # equality
      cmp(eqIndex1, eqIndex2) == 0
      cmp(eqIndex1, eqIndex3) != 0
      cmp(eqIndex1, eqIndex4) != 0

      # ordering
      cmp(eqIndex3, eqIndex4) < 0
      cmp(eqIndex4, eqIndex3) > 0 # Test symmetry

      cmp(eqIndex2, eqIndex4) < 0
      cmp(eqIndex4, eqIndex2) > 0 # Test symmetry

  test "Index equality":
    check:
      eqIndex1 == eqIndex2
      eqIndex1 == eqIndex4
      eqIndex2 != eqIndex3
      eqIndex4 != eqIndex3
