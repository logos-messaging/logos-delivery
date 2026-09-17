{.push raises: [].}

## The libp2p service-discovery operations `WakuKademlia` depends on, as a
## vtable of closures. The native driver runs them on this node's own switch;
## `service_discovery_plugin` sends them to a host outside the node instead.
## Everything around them (lookup loops, PeerManager feeding, mix keys) stays
## in `WakuKademlia` and is shared by both.

import std/sequtils
import chronos, results
import
  libp2p/extended_peer_record,
  libp2p/protocols/service_discovery,
  libp2p/protocols/service_discovery/types

type
  LookupFn* = proc(serviceId: string): Future[Result[seq[ExtendedPeerRecord], string]] {.
    async: (raises: [])
  .}
  LookupRandomFn* =
    proc(): Future[Result[seq[ExtendedPeerRecord], string]] {.async: (raises: []).}
  AdvertiseFn* =
    proc(service: ServiceInfo): Future[Result[void, string]] {.async: (raises: []).}
  ServiceIdFn* =
    proc(serviceId: string): Future[Result[void, string]] {.async: (raises: []).}
  LifecycleFn* = proc(): Future[Result[void, string]] {.async: (raises: []).}

  ServiceDiscoveryDriver* = object
    start*: LifecycleFn
    stop*: LifecycleFn
    lookup*: LookupFn
    lookupRandom*: LookupRandomFn
    startAdvertising*: AdvertiseFn
    stopAdvertising*: ServiceIdFn
    registerInterest*: ServiceIdFn
    unregisterInterest*: ServiceIdFn

proc nativeDriver*(protocol: ServiceDiscovery): ServiceDiscoveryDriver =
  ## In-process kademlia: the protocol is mounted on this node's switch, which
  ## starts it, and it advertises this node's own record.
  ServiceDiscoveryDriver(
    start: proc(): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    stop: proc(): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    lookup: proc(
        serviceId: string
    ): Future[Result[seq[ExtendedPeerRecord], string]] {.async: (raises: []).} =
      let res = catch:
        (await protocol.lookup(serviceId.hashServiceId()))
      let adverts = res.valueOr:
        return err(error.msg)
      let found = adverts.valueOr:
        return err(error)
      ok(found.mapIt(it.data)),
    lookupRandom: proc(): Future[Result[seq[ExtendedPeerRecord], string]] {.
        async: (raises: [])
    .} =
      let res = catch:
        (await protocol.lookupRandom())
      res.mapErr(
        proc(e: ref CatchableError): string =
          e.msg
      ),
    startAdvertising: proc(
        service: ServiceInfo
    ): Future[Result[void, string]] {.async: (raises: []).} =
      protocol.startAdvertising(service),
    stopAdvertising: proc(
        serviceId: string
    ): Future[Result[void, string]] {.async: (raises: []).} =
      let res = catch:
        (await protocol.stopAdvertising(serviceId))
      res.mapErr(
        proc(e: ref CatchableError): string =
          e.msg
      ),
    registerInterest: proc(
        serviceId: string
    ): Future[Result[void, string]] {.async: (raises: []).} =
      discard protocol.registerInterest(serviceId)
      ok(),
    unregisterInterest: proc(
        serviceId: string
    ): Future[Result[void, string]] {.async: (raises: []).} =
      protocol.unregisterInterest(serviceId)
      ok(),
  )
