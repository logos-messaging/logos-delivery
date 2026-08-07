## A no-op NameResolver for the browser edge node.
##
## In a browser the WebSocket API resolves DNS itself, so libp2p must NOT try to
## turn `/dns4/host/...` into `/ip4/<ip>/...` (an IP would break the wss TLS cert,
## which is issued for the hostname). But libp2p's dialer *drops* dns addresses
## entirely when no resolver is set (`expandDnsAddr` returns `@[]`), so the
## transport is never even consulted.
##
## This resolver exists only to make the dialer proceed: it returns a dummy IP so
## `resolveMAddress` yields one `/ip4/0.0.0.0/tcp/<port>/wss` address. The dialer
## separately passes the *original* hostname to `transport.dial(hostname, ...)`,
## and the browser-WS transport dials by that hostname — so the dummy IP is never
## actually used.

{.push raises: [].}

import std/nativesockets
import chronos
import libp2p/nameresolving/nameresolver

type EdgeNameResolver* = ref object of NameResolver

method resolveTxt*(
    self: EdgeNameResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp*(
    self: EdgeNameResolver,
    address: string,
    port: Port,
    domain: Domain = Domain.AF_UNSPEC,
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  # A placeholder address carrying the right port; the host is irrelevant because
  # the transport dials by the hostname the dialer passes alongside.
  return @[initTAddress("0.0.0.0", port)]
