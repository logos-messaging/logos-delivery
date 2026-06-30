{.used.}

import std/[strutils, net], testutils/unittests
import ../testlib/wakucore, ../testlib/wakunode

suite "Waku Core - Published Address":
  test "Test IP 0.0.0.0":
    let node = newTestWakuNode(generateSecp256k1Key())

    check:
      ($node.announcedAddresses).contains("127.0.0.1")

  test "Test custom IP":
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("8.8.8.8"), Port(0))

    check:
      ($node.announcedAddresses).contains("8.8.8.8")
