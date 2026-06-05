{.push raises: [].}

import std/[options, strutils, net]
import chronicles, eth/net/nat, results, nativesockets

logScope:
  topics = "nat"

## Due to the design of nim-eth/nat module we must ensure it is only initialized once.
## see: https://github.com/waku-org/nwaku/issues/2628
## Details: nim-eth/nat module starts a maintenance thread for refreshing the NAT mappings, but everything in the module is global,
## there is no room to store multiple configurations.
## Exact meaning: redirectPorts cannot be called twice in a program lifetime.
## During waku tests we happen to start several node instances in parallel thus resulting in multiple NAT configurations and multiple threads.
## Those threads will dead lock each other in tear down.
var singletonNat: bool = false

# TODO: pass `NatStrategy`, not a string
proc setupNat*(
    natConf, clientId: string, tcpPort, udpPort: Port
): Result[
    tuple[ip: Option[IpAddress], tcpPort: Option[Port], udpPort: Option[Port]], string
] {.gcsafe.} =
  let strategy =
    case natConf.toLowerAscii()
    of "any": NatAny
    of "none": NatNone
    of "upnp": NatUpnp
    of "pmp": NatPmp
    else: NatNone

  var endpoint:
    tuple[ip: Option[IpAddress], tcpPort: Option[Port], udpPort: Option[Port]]

  if strategy != NatNone:
    ## Only initialize the NAT module once
    ## redirectPorts cannot be called twice in a program lifetime.
    ## We can do it as same happens if getExternalIP fails and returns None
    if singletonNat:
      warn "NAT already initialized, skipping as cannot be done multiple times"
    else:
      singletonNat = true
      var extIp = Opt.none(IpAddress)
      try:
        extIp = getExternalIP(strategy)
      except Exception:
        warn "exception in setupNat", error = getCurrentExceptionMsg()

      if extIP.isSome():
        endpoint.ip = some(extIp.get())
        # RedirectPorts in considered a gcsafety violation
        # because it obtains the address of a non-gcsafe proc?
        var extPorts: Opt[(Port, Port)]
        try:
          extPorts = (
            {.gcsafe.}:
              redirectPorts(
                tcpPort = tcpPort, udpPort = udpPort, description = clientId
              )
          )
        except CatchableError:
          # TODO: nat.nim Error: can raise an unlisted exception: Exception. Isolate here for now.
          error "unable to determine external ports"
          extPorts = Opt.none((Port, Port))

        if extPorts.isSome():
          let (extTcpPort, extUdpPort) = extPorts.get()
          endpoint.tcpPort = some(extTcpPort)
          endpoint.udpPort = some(extUdpPort)
  else: # NatNone
    if not natConf.startsWith("extip:"):
      return err("not a valid NAT mechanism: " & $natConf)

    try:
      # any required port redirection is assumed to be done by hand
      endpoint.ip = some(parseIpAddress(natConf[6 ..^ 1]))
    except ValueError:
      return err("not a valid IP address: " & $natConf[6 ..^ 1])

  return ok(endpoint)
