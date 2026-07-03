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

  test "rollbackNonce lets the next getNonce reissue the same id":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    let first = nm.getNonce().valueOr:
      raiseAssert $error
    nm.rollbackNonce()
    let reissued = nm.getNonce().valueOr:
      raiseAssert $error

    check:
      first == 0.uint
      reissued == first
      nm.nextNonce == 1.uint

  test "rollbackNonce frees the message id so nonceLimit is not exceeded":
    let nm = NonceManager.init(nonceLimit = 1.uint)
    discard nm.getNonce().valueOr:
      raiseAssert $error
    # Without rollback a second call would fail (nonceLimit = 1, i.e. one
    # message id per epoch). Rollback returns the id and the retry succeeds
    # using the same id — the on-chain slashing threshold is not crossed.
    nm.rollbackNonce()
    let retry = nm.getNonce()

    check:
      retry.isOk()
      retry.get() == 0.uint

  test "rollbackNonce is a no-op when no nonce has been issued":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    nm.rollbackNonce()

    check:
      nm.nextNonce == 0.uint
