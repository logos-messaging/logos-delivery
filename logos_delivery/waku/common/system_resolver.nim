## Name resolution through the host's own configuration, for a node given no
## DNS servers.
{.push raises: [].}

import std/[net, sequtils, strutils]
import chronos, chronicles, results, stew/io2
import libp2p/crypto/rng, libp2p/nameresolving/[nameresolver, dnsresolver]
import ./getaddrinfo_async

logScope:
  topics = "waku system resolver"

const
  DefaultResolvConfPath = "/etc/resolv.conf"
  DefaultFallbackServers* = @[initTAddress("1.1.1.1:53"), initTAddress("1.0.0.1:53")]
    ## Asked for TXT records when the host lists no name server of its own.

type SystemResolver* = ref object of NameResolver
  ## A and AAAA go through the OS resolver. TXT needs a DNS client, since the
  ## OS resolver has no TXT lookup; it is pointed at the host's name servers.
  resolvConfPath: string
  txtFallback: seq[TransportAddress]
  rng: Rng

proc hostNameServers*(resolvConfPath = DefaultResolvConfPath): seq[TransportAddress] =
  ## The `nameserver` entries of the file, on port 53, in file order. Empty
  ## when the file is missing or lists none: Windows, or a container with no
  ## resolver configured.
  let content = readAllChars(resolvConfPath).valueOr:
    debug "No resolv.conf to read name servers from",
      path = resolvConfPath, error = ioErrorMsg(error)
    return @[]

  var servers: seq[TransportAddress]
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line[0] in {'#', ';'}:
      continue
    let fields = line.splitWhitespace()
    if fields.len < 2 or fields[0] != "nameserver":
      continue
    let ip =
      try:
        parseIpAddress(fields[1])
      except ValueError:
        debug "Skipping a name server that is not an IP address",
          path = resolvConfPath, entry = fields[1]
        continue
    servers.add(initTAddress(ip, Port(53)))

  return servers

proc new*(
    T: typedesc[SystemResolver],
    resolvConfPath = DefaultResolvConfPath,
    txtFallback: seq[TransportAddress] = DefaultFallbackServers,
): T =
  T(resolvConfPath: resolvConfPath, txtFallback: txtFallback, rng: newRng())

proc txtNameServers*(self: SystemResolver): seq[TransportAddress] =
  ## The host's name servers as of now, or `txtFallback` when it lists none.
  ## Read per lookup so that a network change is followed; TXT lookups are
  ## rare (`/dnsaddr` dials, `enrtree` walks), so the file read stays off the
  ## hot path.
  let hostServers = hostNameServers(self.resolvConfPath)
  if hostServers.len > 0: hostServers else: self.txtFallback

method resolveIp*(
    self: SystemResolver, address: string, port: Port, domain: Domain = Domain.AF_UNSPEC
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  ## Through the OS resolver. Empty for a name with no record, as `DnsResolver`
  ## answers.
  let texts = (await getAddrInfoAsync(address, domain)).valueOr:
    debug "Host resolver returned no address", address, error = error
    return @[]
  return texts.mapIt(initTAddress(it, port))

method resolveTxt*(
    self: SystemResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  await DnsResolver.new(self.txtNameServers(), self.rng).resolveTxt(address)

proc newNameResolver*(nameServers: seq[IpAddress]): NameResolver =
  ## `SystemResolver` when the list is empty, else a `DnsResolver` on the
  ## listed servers, port 53.
  if nameServers.len == 0:
    return SystemResolver.new()
  return DnsResolver.new(nameServers.mapIt(initTAddress(it, Port(53))))
