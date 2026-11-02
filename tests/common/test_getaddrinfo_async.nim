{.used.}

import std/[sequtils, strutils]
import chronos, results, testutils/unittests
import logos_delivery/waku/common/getaddrinfo_async

suite "getAddrInfoAsync":
  asyncTest "localhost resolves to a loopback address":
    let addrs = (await getAddrInfoAsync("localhost", Domain.AF_INET)).expect("name")
    check:
      "127.0.0.1" in addrs
      addrs.allIt(':' notin it)
      addrs.deduplicate().len == addrs.len

  asyncTest "an IPv6 lookup never returns a mapped IPv4 address":
    ## The stdlib's convenience overload sets AI_V4MAPPED for AF_INET6, which
    ## would turn an IPv4-only name into `::ffff:a.b.c.d` and then, through
    ## `getAddrString`, into a bare IPv4 text.
    let res = await getAddrInfoAsync("localhost", Domain.AF_INET6)
    if res.isOk():
      check:
        "127.0.0.1" notin res.get()
        res.get().allIt(':' in it)

  asyncTest "an unknown host is an error":
    check (await getAddrInfoAsync("host.invalid")).isErr()

  asyncTest "an empty name is an error":
    check (await getAddrInfoAsync("")).isErr()

  asyncTest "a name longer than the buffer is an error":
    check (await getAddrInfoAsync('a'.repeat(300))).isErr()
