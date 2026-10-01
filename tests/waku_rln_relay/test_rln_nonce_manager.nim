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
