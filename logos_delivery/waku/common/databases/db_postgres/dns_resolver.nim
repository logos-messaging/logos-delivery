## Resolves a host name off the event loop: libpq resolves host names with a
## blocking getaddrinfo, which stalls every other task while the resolver is slow.
{.push raises: [].}

import std/[net, strutils]
import chronos, results
import ../../getaddrinfo_async

proc resolveHostAddr*(host: string): Future[Result[string, string]] {.async.} =
  ## The comma separated IP addresses of `host`, or "" when libpq needs no
  ## lookup: an IP literal or a unix socket directory.
  if host.len == 0 or host[0] == '/' or host.isIpAddress():
    return ok("")

  ## Every address is kept, in the resolver's order, so that libpq still
  ## falls back from one to the next as it does when it resolves itself.
  let addrs = (await getAddrInfoAsync(host)).valueOr:
    return err(error)

  return ok(addrs.join(","))
