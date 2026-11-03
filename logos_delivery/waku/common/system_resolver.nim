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

type
  ResolvConf* = object
    servers*: seq[TransportAddress]
      ## the usable `nameserver` entries, port 53, in file order
    skippedEntries*: int ## `nameserver` lines whose value is not an IP address

  SystemResolver* = ref object of NameResolver
    ## A and AAAA go through the OS resolver. TXT needs a DNS client, since the
    ## OS resolver has no TXT lookup; it is pointed at the host's name servers.
    resolvConfPath: string
    txtFallback: seq[TransportAddress]
    fallbackWarned: bool ## the fallback is logged once, not on every lookup
    rng: Rng

proc readResolvConf*(resolvConfPath = DefaultResolvConfPath): ResolvConf =
  ## No servers when the file is missing or lists none: Windows, or a container
  ## with no resolver configured.
  let content = readAllChars(resolvConfPath).valueOr:
    debug "No resolv.conf to read name servers from",
      path = resolvConfPath, error = ioErrorMsg(error)
    return ResolvConf()

  var conf: ResolvConf
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
        ## A zone-scoped address such as `fe80::1%eth0` lands here. It is valid
        ## host configuration, but a transport address carries no zone, so the
        ## entry cannot be used.
        debug "Skipping a name server that is not an IP address",
          path = resolvConfPath, entry = fields[1]
        conf.skippedEntries.inc()
        continue
    conf.servers.add(initTAddress(ip, Port(53)))

  return conf

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
  let conf = readResolvConf(self.resolvConfPath)
  if conf.servers.len > 0:
    self.fallbackWarned = false
    return conf.servers

  if conf.skippedEntries > 0 and not self.fallbackWarned:
    ## The host does configure name servers, but none can be used, so TXT
    ## lookups leave the host's DNS without the operator knowing.
    warn "No usable name server in resolv.conf, TXT lookups use the fallback",
      path = self.resolvConfPath,
      skipped = conf.skippedEntries,
      fallback = self.txtFallback.mapIt($it).join(",")
    self.fallbackWarned = true
  return self.txtFallback

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
