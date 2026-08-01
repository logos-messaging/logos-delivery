import std/net
import chronos, results, testutils/unittests

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

  test "map strategies to libp2p NATConfig":
    check:
      toNatConfig(NatStrategy(kind: NatUpnp)).get().portMapping.get().mode ==
        PortMappingMode.Upnp
      toNatConfig(NatStrategy(kind: NatAny)).get().portMapping.get().mode ==
        PortMappingMode.Upnp
      toNatConfig(NatStrategy(kind: NatPmp)).get().portMapping.get().mode ==
        PortMappingMode.NatPmp
      toNatConfig(NatStrategy(kind: NatNone)).isNone()
      toNatConfig(NatStrategy(kind: NatExtIp, extIp: parseIpAddress("203.0.113.4")))
        .isNone()

  asyncTest "fallback port mapper factory only overrides for any":
    check:
      natPortMapperFactory(NatStrategy(kind: NatNone)).isNil()
      natPortMapperFactory(NatStrategy(kind: NatUpnp)).isNil()
      natPortMapperFactory(NatStrategy(kind: NatPmp)).isNil()

    let factory = natPortMapperFactory(NatStrategy(kind: NatAny))
    check not factory.isNil()

    let mapper = factory(PortMappingMode.Upnp)
    check:
      mapper.isSome()
      mapper.get() of FallbackPortMapper

    # The candidate mappers own worker threads: close before test teardown.
    await mapper.get().close()
