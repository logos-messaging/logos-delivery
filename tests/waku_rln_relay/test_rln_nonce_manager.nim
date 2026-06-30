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
