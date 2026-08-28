import chronicles, std/strutils, results
import ../waku_conf

logScope:
  topics = "waku conf builder dns discovery"

##################################
## DNS Discovery Config Builder ##
##################################
type DnsDiscoveryConfBuilder* = object
  enrTreeUrl*: Opt[string]

proc init*(T: type DnsDiscoveryConfBuilder): DnsDiscoveryConfBuilder =
  DnsDiscoveryConfBuilder()

proc withEnrTreeUrl*(b: var DnsDiscoveryConfBuilder, enrTreeUrl: string) =
  b.enrTreeUrl = Opt.some(enrTreeUrl)

proc build*(b: DnsDiscoveryConfBuilder): Result[Opt[DnsDiscoveryConf], string] =
  if b.enrTreeUrl.isNone():
    return ok(Opt.none(DnsDiscoveryConf))

  if isEmptyOrWhiteSpace(b.enrTreeUrl.get()):
    return err("dnsDiscovery.enrTreeUrl cannot be an empty string")

  return ok(Opt.some(DnsDiscoveryConf(enrTreeUrl: b.enrTreeUrl.get())))
