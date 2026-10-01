{.used.}

import testutils/unittests, results
import logos_delivery/waku/rln/rln_evm/nonce_manager, logos_delivery/waku/rln/types

suite "Nonce manager":
  test "starts with no ids drawn":
    let nm = NonceManager.init(nonceLimit = 100)

    check:
      nm.nonceLimit == 100
      nm.nextId == 0
      nm.spent(0) == 0

  test "hands out consecutive ids within one epoch":
    let nm = NonceManager.init(nonceLimit = 100)

    check:
      nm.reserve(7).get() == 0
      nm.reserve(7).get() == 1
      nm.reserve(7).get() == 2
      nm.epochIndex == 7
      nm.spent(7) == 3

  test "a later epoch restarts the count":
    let nm = NonceManager.init(nonceLimit = 100)
    discard nm.reserve(7).get()
    discard nm.reserve(7).get()

    check:
      nm.reserve(8).get() == 0
      nm.epochIndex == 8
      nm.spent(8) == 1
      nm.spent(7) == 0

  test "an earlier epoch is refused":
    ## The counter never moves back: an id drawn again for an epoch already
    ## left behind could repeat one that was sent.
    let nm = NonceManager.init(nonceLimit = 100)
    discard nm.reserve(8).get()

    let res = nm.reserve(7)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.Permanent
      nm.epochIndex == 8
      nm.spent(8) == 1

  test "fails at the limit without consuming an id":
    let nm = NonceManager.init(nonceLimit = 1)
    check nm.reserve(7).get() == 0

    let res = nm.reserve(7)
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.BudgetExhausted
      nm.spent(7) == 1

  test "the next epoch has a fresh budget after the limit":
    let nm = NonceManager.init(nonceLimit = 1)
    discard nm.reserve(7).get()
    check nm.reserve(7).isErr()

    check:
      nm.reserve(8).get() == 0
      nm.spent(8) == 1

  test "release returns the latest id to the epoch's budget":
    let nm = NonceManager.init(nonceLimit = 100)
    discard nm.reserve(7).get()
    let id = nm.reserve(7).get()

    nm.release(7, id)
    check:
      nm.spent(7) == 1
      nm.reserve(7).get() == id

  test "release keeps an id spent once the counter has moved past it":
    ## A later reservation may already be in a proof, so the counter cannot
    ## step back over it.
    let nm = NonceManager.init(nonceLimit = 100)
    let older = nm.reserve(7).get()
    discard nm.reserve(7).get()

    nm.release(7, older)
    check nm.spent(7) == 2

    let last = nm.reserve(7).get()
    discard nm.reserve(8).get()
    nm.release(7, last)
    check:
      nm.epochIndex == 8
      nm.spent(8) == 1

  test "release on a fresh manager does nothing":
    let nm = NonceManager.init(nonceLimit = 100)
    nm.release(0, 0)
    check:
      nm.spent(0) == 0
      nm.reserve(0).get() == 0

  test "restore resumes the stored epoch at the next unused id":
    let nm = NonceManager.init(nonceLimit = 100)
    nm.restore(7, 5)

    check:
      nm.epochIndex == 7
      nm.spent(7) == 5
      nm.reserve(7).get() == 5

  test "restore clamps a count above the limit to a spent epoch":
    let nm = NonceManager.init(nonceLimit = 3)
    nm.restore(7, 10)

    let res = nm.reserve(7)
    check:
      nm.spent(7) == 3
      res.isErr()
      res.error.kind == RlnErrorKind.BudgetExhausted

  test "after restore, an earlier epoch is refused and a later one starts fresh":
    ## The stored epoch can be ahead of the clock (the clock went back, or a
    ## message was stamped ahead); the counter still never moves back.
    let nm = NonceManager.init(nonceLimit = 100)
    nm.restore(8, 2)

    let earlier = nm.reserve(7)
    check:
      earlier.isErr()
      earlier.error.kind == RlnErrorKind.Permanent
      nm.reserve(9).get() == 0
      nm.epochIndex == 9

  test "restore never moves the counter back":
    let nm = NonceManager.init(nonceLimit = 100)
    discard nm.reserve(7).get()
    discard nm.reserve(7).get()
    discard nm.reserve(7).get()

    nm.restore(7, 1) # fewer ids in the same epoch
    nm.restore(6, 50) # an earlier epoch
    check:
      nm.epochIndex == 7
      nm.spent(7) == 3

    nm.restore(7, 5) # more ids in the same epoch
    check nm.spent(7) == 5
