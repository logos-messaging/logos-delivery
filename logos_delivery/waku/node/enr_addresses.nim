{.push raises: [].}

## The address fields of the node's ENR.
##
## `ip`, `tcp` and `udp` name one host, decided from the current facts:
## the host discv5 learned from its peers, else the first announced IPv4
## TCP endpoint, else the configured baseline. Placeholders never enter.

import std/[net, sequtils]
import results, chronicles
import eth/keys, eth/p2p/discoveryv5/enr
import libp2p/[multiaddress, wire], libp2p/crypto/crypto
import ../net/net_config, ../waku_enr

logScope:
  topics = "waku enr"

type
  DiscoveryEndpoint* = tuple[ip: IpAddress, udp: Port]
  EnrBaseline* = tuple[ip: Opt[IpAddress], tcp: Opt[Port]]
  Scalars = tuple[ip: Opt[IpAddress], tcp: Opt[Port], udp: Opt[Port]]
  TcpEndpoint = tuple[ip: IpAddress, tcp: Port]

const ScalarKeys = ["id", "secp256k1", "ip", "ip6", "tcp", "tcp6", "udp", "udp6"]

proc tcpEndpoints(addrs: seq[MultiAddress]): seq[TcpEndpoint] =
  ## IPv4 only: nim-eth writes an IPv6 host as `ip6` but its port as `tcp`,
  ## next to whatever `ip` the record has. IPv6 travels in the field instead.
  var endpoints: seq[TcpEndpoint]
  for ma in addrs:
    if ma.isCircuitRelayMA() or not ma.isP2pTcpAddress() or not ma.isDialableMA():
      continue
    let ip = ma.getIp().valueOr:
      continue
    if ip.family != IpAddressFamily.IPv4:
      continue
    let address = initTAddress(ma).valueOr:
      continue
    endpoints.add((ip: ip, tcp: address.port))
  return endpoints

proc toEnrKey(key: crypto.PrivateKey): Result[keys.PrivateKey, string] =
  let bytes = key.getRawBytes().valueOr:
    return err("failed to read the node key: " & $error)
  let pk = keys.PrivateKey.fromRaw(bytes).valueOr:
    return err("failed to parse the node key: " & $error)
  return ok(pk)

proc rebuild(
    record: var enr.Record,
    pk: keys.PrivateKey,
    scalars: Scalars,
    fields: seq[FieldPair],
): Result[void, string] =
  ## Rebuilt, not updated: `Record.update` cannot remove a field, and an
  ## address that went away has to go away with it.
  if record.publicKey != pk.toPublicKey():
    return err("the node key does not match the record")
  if record.seqNum == high(uint64):
    return err("maximum ENR sequence number reached")
  let replaced = fields.mapIt(it[0])
  let kept = record.pairs.filterIt(it[0] notin ScalarKeys and it[0] notin replaced)
  let rebuilt = enr.Record.init(
    record.seqNum + 1, pk, scalars.ip, scalars.tcp, scalars.udp, kept & fields
  ).valueOr:
    return err($error)
  record = rebuilt
  return ok()

proc updateEnrAddresses*(
    record: var enr.Record,
    key: crypto.PrivateKey,
    addrs: seq[MultiAddress],
    baseline: EnrBaseline,
    learned = Opt.none(DiscoveryEndpoint),
): Result[void, string] =
  ## Write `addrs` into `record`: the multiaddrs field, and one endpoint in
  ## the scalars. A port is written only next to the host it belongs to.
  let pk = ?key.toEnrKey()
  let typed = record.toTyped().valueOr:
    return err("failed to read the record: " & $error)
  let usable = addrs.filterIt(it.isDialableMA())
  let endpoints = tcpEndpoints(usable)
  let udp =
    if typed.udp.isSome():
      Opt.some(Port(typed.udp.get()))
    else:
      Opt.none(Port)

  let scalars: Scalars =
    if learned.isSome():
      let host = learned.get().ip
      let onHost = endpoints.filterIt(it.ip == host)
      let tcp =
        if onHost.len > 0:
          Opt.some(onHost[0].tcp)
        else:
          Opt.none(Port)
      (ip: Opt.some(host), tcp: tcp, udp: Opt.some(learned.get().udp))
    elif endpoints.len > 0:
      (ip: Opt.some(endpoints[0].ip), tcp: Opt.some(endpoints[0].tcp), udp: udp)
    else:
      (ip: baseline.ip, tcp: baseline.tcp, udp: udp)

  let sorted =
    usable.filterIt(it.isCircuitRelayMA()) & usable.filterIt(not it.isCircuitRelayMA())
  ## Dropping tail entries only helps when the record is too large.
  for retained in countdown(sorted.len, 0):
    let fields =
      @[toFieldPair(MultiaddrEnrField, encodeMultiaddrs(sorted[0 ..< retained]))]
    if record.rebuild(pk, scalars, fields).isOk():
      debug "ENR addresses updated", retained = retained, total = sorted.len
      return ok()
  return err("failed to update ENR addresses at every prefix")
