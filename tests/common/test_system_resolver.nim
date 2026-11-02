{.used.}

import std/[os, sequtils]
import chronos, testutils/unittests
import libp2p/multiaddress, libp2p/nameresolving/[nameresolver, dnsresolver]
import logos_delivery/waku/common/system_resolver

suite "SystemResolver - host name servers":
  test "parses nameserver lines":
    let path = getTempDir() / "resolv-" & $getCurrentProcessId() & ".conf"
    writeFile(
      path,
      """
# comment
nameserver 127.0.0.53
options edns0 trust-ad
search .
; another comment
  nameserver   2606:4700:4700::1111
nameserver not-an-ip
nameserver
""",
    )
    defer:
      removeFile(path)

    check hostNameServers(path) ==
      @[initTAddress("127.0.0.53:53"), initTAddress("[2606:4700:4700::1111]:53")]

  test "a missing file gives no servers":
    check hostNameServers(getTempDir() / "no-such-resolv.conf").len == 0

suite "SystemResolver - resolution":
  asyncTest "resolveIp honours the family":
    let resolver = SystemResolver.new()
    let addrs = await resolver.resolveIp("localhost", Port(1), Domain.AF_INET)
    check:
      initTAddress("127.0.0.1:1") in addrs
      addrs.allIt(it.family == AddressFamily.IPv4)

  asyncTest "an unknown name resolves to nothing":
    let resolver = SystemResolver.new()
    check (await resolver.resolveIp("host.invalid", Port(1))).len == 0

  asyncTest "a dns4 multiaddr resolves to the ip4 form":
    let resolver = SystemResolver.new()
    let name = MultiAddress.init("/dns4/localhost/tcp/60000").tryGet()
    let resolved = await resolver.resolveMAddress(name)
    check MultiAddress.init("/ip4/127.0.0.1/tcp/60000").tryGet() in resolved

suite "SystemResolver - TXT name servers":
  test "a host with no name servers falls back to the given ones":
    let resolver = SystemResolver.new(
      resolvConfPath = getTempDir() / "no-such-resolv.conf",
      txtFallback = @[initTAddress("10.0.0.2:53")],
    )
    check resolver.txtNameServers() == @[initTAddress("10.0.0.2:53")]

  test "the host's name servers are read at lookup time":
    let path = getTempDir() / "resolv-live-" & $getCurrentProcessId() & ".conf"
    writeFile(path, "nameserver 10.0.0.1\n")
    defer:
      removeFile(path)
    let resolver = SystemResolver.new(resolvConfPath = path)

    check resolver.txtNameServers() == @[initTAddress("10.0.0.1:53")]

    writeFile(path, "nameserver 10.0.0.3\n")
    check resolver.txtNameServers() == @[initTAddress("10.0.0.3:53")]

suite "SystemResolver - constructor":
  test "no servers gives the system resolver":
    check newNameResolver(@[]) of SystemResolver

  test "listed servers give a dns resolver on port 53":
    let resolver = newNameResolver(@[parseIpAddress("10.0.0.1")])
    check resolver of DnsResolver
    check DnsResolver(resolver).nameServers == @[initTAddress("10.0.0.1:53")]
