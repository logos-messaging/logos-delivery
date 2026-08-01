import std/net
import results, testutils/unittests

import ../logos_delivery/waku/net/nat_config

suite "NAT strategy configuration":
  test "parse named strategies":
    check:
      parseNatStrategy("none").get().kind == NatNone
      parseNatStrategy("any").get().kind == NatAny
      parseNatStrategy("UPNP").get().kind == NatUpnp
      parseNatStrategy("pMp").get().kind == NatPmp

  test "parse static external IP":
    let strategy = parseNatStrategy("extip:203.0.113.4").get()

    check:
      strategy.kind == NatExtIp
      strategy.extIp == parseIpAddress("203.0.113.4")
      $strategy == "extip:203.0.113.4"

  test "reject invalid strategies":
    check:
      parseNatStrategy("").isErr()
      parseNatStrategy("automatic").isErr()
      parseNatStrategy("extip:not-an-ip").isErr()
