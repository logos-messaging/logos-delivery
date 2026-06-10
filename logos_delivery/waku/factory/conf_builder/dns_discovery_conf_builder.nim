import chronicles, std/[net, options, strutils], results
import ../waku_conf

logScope:
  topics = "waku conf builder dns discovery"

##################################
## DNS Discovery Config Builder ##
##################################
type DnsDiscoveryConfBuilder* = object
  enrTreeUrl*: Option[string]
  nameServers*: seq[IpAddress]

proc init*(T: type DnsDiscoveryConfBuilder): DnsDiscoveryConfBuilder =
  DnsDiscoveryConfBuilder()

proc withEnrTreeUrl*(b: var DnsDiscoveryConfBuilder, enrTreeUrl: string) =
  b.enrTreeUrl = some(enrTreeUrl)

proc withNameServers*(b: var DnsDiscoveryConfBuilder, nameServers: seq[IpAddress]) =
  b.nameServers = nameServers

proc build*(b: DnsDiscoveryConfBuilder): Result[Option[DnsDiscoveryConf], string] =
  if b.enrTreeUrl.isNone():
    return ok(none(DnsDiscoveryConf))

  if isEmptyOrWhiteSpace(b.enrTreeUrl.get()):
    return err("dnsDiscovery.enrTreeUrl cannot be an empty string")
  if b.nameServers.len == 0:
    return err("dnsDiscovery.nameServers is not specified")

  return ok(
    some(DnsDiscoveryConf(nameServers: b.nameServers, enrTreeUrl: b.enrTreeUrl.get()))
  )
