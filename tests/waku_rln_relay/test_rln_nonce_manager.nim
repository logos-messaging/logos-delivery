{.used.}

import testutils/unittests, chronos, os
import logos_delivery/waku/rln/nonce_manager

suite "Nonce manager":
  test "should initialize successfully":
    let nm = NonceManager.init(nonceLimit = 100.uint)

    check:
      nm.nonceLimit == 100.uint
      nm.nextNonce == 0.uint

  test "should generate a new nonce":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    let nonce = nm.getNonce().valueOr:
      raiseAssert $error

    check:
      nonce == 0.uint
      nm.nextNonce == 1.uint

  test "should fail to generate a new nonce if limit is reached":
    let nm = NonceManager.init(nonceLimit = 1.uint)
    let nonce = nm.getNonce().valueOr:
      raiseAssert $error
    let failedNonceRes = nm.getNonce()

    check:
      failedNonceRes.isErr()
      failedNonceRes.error.kind == NonceManagerErrorKind.NonceLimitReached

  test "should generate a new nonce if epoch is crossed":
    let nm = NonceManager.init(nonceLimit = 1.uint, epoch = float(0.000001))
    let nonce = nm.getNonce().valueOr:
      raiseAssert $error
    sleep(1)
    let nonce2 = nm.getNonce().valueOr:
      raiseAssert $error

    check:
      nonce == 0.uint
      nonce2 == 0.uint

  test "rollbackNonce reclaims the last-drawn id when counter has not advanced":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    let first = nm.getNonce().valueOr:
      raiseAssert $error
    check nm.rollbackNonce(first)
    let reissued = nm.getNonce().valueOr:
      raiseAssert $error

    check:
      first == 0.uint
      reissued == first
      nm.nextNonce == 1.uint

  test "rollbackNonce is a no-op when another draw has advanced the counter":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    let first = nm.getNonce().valueOr:
      raiseAssert $error
    # A second draw slips in — simulates concurrent publish between attempt 1
    # and the retry. The counter now points past first+1.
    discard nm.getNonce().valueOr:
      raiseAssert $error
    check not nm.rollbackNonce(first)
    check nm.nextNonce == 2.uint

  test "rollbackNonce is a no-op when no nonce has been issued":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    check not nm.rollbackNonce(Nonce(0))

    check:
      nm.nextNonce == 0.uint
