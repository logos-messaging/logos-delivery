{.push raises: [].}

## IPeerDiscovery backed by an external service-discovery plugin (today:
## logos-libp2p-module, driven by glue in logos-delivery-module).
##
## This implementation deliberately has no libp2p dependency: every verb is a
## blocking call into the plugin vtable installed through the
## `SetServiceDiscoveryPlugin` request broker. Calls run on the node's
## processing thread and return their result directly — no completion
## callbacks, no events from the plugin back into us.

import std/sequtils
import chronos, chronicles, results
import brokers/broker_implement
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/service_discovery_plugin

export peer_discovery_interface, service_discovery_plugin

logScope:
  topics = "waku discovery external"

const ExternalBackendId* = "service-ext"

type ExternalServiceDiscovery* = ref object of IPeerDiscovery
  plugin: Opt[ServiceDiscoveryPlugin]
  running: bool
  nodeCtx: BrokerContext

proc toDiscoveredPeer(peer: LdDiscoPeer): DiscoveredPeer =
  var addrs: seq[string]
  for i in 0 ..< peer.addrsLen.int:
    if not peer.addrs[i].isNil():
      addrs.add($peer.addrs[i])

  var services: seq[DiscoveredService]
  for i in 0 ..< peer.servicesLen.int:
    let svc = peer.services[i]
    var data: seq[byte]
    for j in 0 ..< svc.dataLen.int:
      data.add(svc.data[j])
    services.add(
      DiscoveredService(id: (if svc.id.isNil(): "" else: $svc.id), data: data)
    )

  DiscoveredPeer(
    peerId: (if peer.peerId.isNil(): "" else: $peer.peerId),
    addrs: addrs,
    enr: (if peer.enr.isNil(): "" else: $peer.enr),
    seqNo: peer.seqNo,
    services: services,
  )

proc errText(errBuf: string, code: cint, op: string): string =
  ## Reads the plugin's NUL-terminated message out of our buffer.
  var msg = ""
  for c in errBuf:
    if c == '\0':
      break
    msg.add(c)
  if msg.len == 0:
    msg = "status " & $code
  "external backend: " & op & " failed: " & msg

proc collect(
    plugin: ServiceDiscoveryPlugin, list: var LdDiscoPeerList
): seq[DiscoveredPeer] =
  ## Copies the plugin-owned list, then hands it back for release.
  var found: seq[DiscoveredPeer]
  for i in 0 ..< list.peersLen.int:
    found.add(list.peers[i].toDiscoveredPeer())
  plugin.freePeerList(plugin.pluginCtx, addr list)
  found

BrokerImplement ExternalServiceDiscovery of IPeerDiscovery:
  proc new(T: typedesc[ExternalServiceDiscovery]): ExternalServiceDiscovery =
    let self = ExternalServiceDiscovery(
      plugin: Opt.none(ServiceDiscoveryPlugin), nodeCtx: globalBrokerContext()
    )

    ## Registration rides the brokers, so the FFI layer needs no handle on
    ## this instance.
    discard SetServiceDiscoveryPlugin.reprovideIt(self.nodeCtx):
      ?plugin.validate()
      self.plugin = Opt.some(plugin)
      info "service discovery plugin installed", abiVersion = plugin.abiVersion
      ok()

    discard ClearServiceDiscoveryPlugin.reprovideIt(self.nodeCtx):
      self.plugin = Opt.none(ServiceDiscoveryPlugin)
      info "service discovery plugin cleared"
      ok()

    self

  method backendInfo(
      self: ExternalServiceDiscovery
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(
      DiscoveryBackendInfo(
        id: ExternalBackendId,
        running: self.running,
        keyKinds: @["svc", "shard", "cap"],
        boundPorts: @[],
      )
    )

  method startDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if self.running:
      return ok()
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.start(plugin.pluginCtx, errBuf.cstring, errBuf.len.csize_t)
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "start"))

    self.running = true
    ok()

  method stopDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if not self.running:
      return ok()
    self.running = false
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.stop(plugin.pluginCtx, errBuf.cstring, errBuf.len.csize_t)
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "stop"))
    ok()

  method lookupServicePeers(
      self: ExternalServiceDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var
      errBuf = newString(LdDiscoErrBufLen)
      list = LdDiscoPeerList()
    let rc = plugin.lookup(
      plugin.pluginCtx,
      key.cstring,
      limit.int64,
      addr list,
      errBuf.cstring,
      errBuf.len.csize_t,
    )
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "lookup"))
    ok(plugin.collect(list))

  method lookupRandom(
      self: ExternalServiceDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var
      errBuf = newString(LdDiscoErrBufLen)
      list = LdDiscoPeerList()
    let rc = plugin.randomLookup(
      plugin.pluginCtx, addr list, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "randomLookup"))
    ok(plugin.collect(list))

  method startAdvertising(
      self: ExternalServiceDiscovery, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var
      errBuf = newString(LdDiscoErrBufLen)
      dataCopy = data
      recordCopy = record
    let
      dataPtr =
        if dataCopy.len == 0:
          nil
        else:
          cast[ptr UncheckedArray[uint8]](addr dataCopy[0])
      recordPtr =
        if recordCopy.len == 0:
          nil
        else:
          cast[ptr UncheckedArray[uint8]](addr recordCopy[0])
      rc = plugin.startAdvertising(
        plugin.pluginCtx, key.cstring, dataPtr, dataCopy.len.csize_t, recordPtr,
        recordCopy.len.csize_t, errBuf.cstring, errBuf.len.csize_t,
      )
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "startAdvertising"))
    ok()

  method stopAdvertising(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.stopAdvertising(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "stopAdvertising"))
    ok()

  method registerInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.registerInterest(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "registerInterest"))
    ok()

  method unregisterInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var errBuf = newString(LdDiscoErrBufLen)
    let rc = plugin.unregisterInterest(
      plugin.pluginCtx, key.cstring, errBuf.cstring, errBuf.len.csize_t
    )
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "unregisterInterest"))
    ok()

  method addBootstrapEntries(
      self: ExternalServiceDiscovery, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    if entries.len == 0:
      return ok()
    let plugin = self.plugin.valueOr:
      return err("external backend: no service discovery plugin installed")

    var
      errBuf = newString(LdDiscoErrBufLen)
      cstrs = entries.mapIt(it.cstring)
    let rc = plugin.addBootstrapEntries(
      plugin.pluginCtx,
      cast[ptr UncheckedArray[cstring]](addr cstrs[0]),
      cstrs.len.csize_t,
      errBuf.cstring,
      errBuf.len.csize_t,
    )
    if rc != LdDiscoOk:
      return err(errText(errBuf, rc, "addBootstrapEntries"))
    ok()
