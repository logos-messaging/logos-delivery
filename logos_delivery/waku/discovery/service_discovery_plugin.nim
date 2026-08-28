{.push raises: [].}

## Nim mirror of `library/logosdelivery_service_discovery.h` — the service
## discovery plugin ABI — plus the request broker an external entity uses to
## install a plugin.
##
## Calling model (POC): every entry point is a plain blocking request invoked
## on the node's processing thread. No completion callbacks, no events from
## the plugin back into logos-delivery.

import chronos, results
import brokers/request_broker

export request_broker

const
  LdDiscoAbiVersion* = 1'u32
  LdDiscoOk* = 0.cint
  LdDiscoError* = 1.cint
  LdDiscoErrBufLen* = 512

type LdDiscoService* {.bycopy.} = object
  id*: cstring
  data*: ptr UncheckedArray[uint8]
  dataLen*: csize_t

type LdDiscoPeer* {.bycopy.} = object
  peerId*: cstring
  addrs*: ptr UncheckedArray[cstring]
  addrsLen*: csize_t
  enr*: cstring
  seqNo*: uint64
  services*: ptr UncheckedArray[LdDiscoService]
  servicesLen*: csize_t

type LdDiscoPeerList* {.bycopy.} = object
  peers*: ptr UncheckedArray[LdDiscoPeer]
  peersLen*: csize_t
  owner*: pointer

type
  LdDiscoStartFn* = proc(pluginCtx: pointer, errBuf: cstring, errBufLen: csize_t): cint {.
    cdecl, gcsafe, raises: []
  .}

  LdDiscoStopFn* = LdDiscoStartFn

  LdDiscoLookupFn* = proc(
    pluginCtx: pointer,
    key: cstring,
    limit: int64,
    outPeers: ptr LdDiscoPeerList,
    errBuf: cstring,
    errBufLen: csize_t,
  ): cint {.cdecl, gcsafe, raises: [].}

  LdDiscoRandomLookupFn* = proc(
    pluginCtx: pointer,
    outPeers: ptr LdDiscoPeerList,
    errBuf: cstring,
    errBufLen: csize_t,
  ): cint {.cdecl, gcsafe, raises: [].}

  LdDiscoFreePeerListFn* =
    proc(pluginCtx: pointer, list: ptr LdDiscoPeerList) {.cdecl, gcsafe, raises: [].}

  LdDiscoStartAdvertisingFn* = proc(
    pluginCtx: pointer,
    key: cstring,
    data: ptr UncheckedArray[uint8],
    dataLen: csize_t,
    record: ptr UncheckedArray[uint8],
    recordLen: csize_t,
    errBuf: cstring,
    errBufLen: csize_t,
  ): cint {.cdecl, gcsafe, raises: [].}

  LdDiscoKeyFn* = proc(
    pluginCtx: pointer, key: cstring, errBuf: cstring, errBufLen: csize_t
  ): cint {.cdecl, gcsafe, raises: [].}
    ## stopAdvertising / registerInterest / unregisterInterest

  LdDiscoAddBootstrapEntriesFn* = proc(
    pluginCtx: pointer,
    entries: ptr UncheckedArray[cstring],
    entriesLen: csize_t,
    errBuf: cstring,
    errBufLen: csize_t,
  ): cint {.cdecl, gcsafe, raises: [].}

type ServiceDiscoveryPlugin* {.bycopy.} = object
  ## Layout-compatible with `LdServiceDiscoveryPlugin`.
  abiVersion*: uint32
  pluginCtx*: pointer
  start*: LdDiscoStartFn
  stop*: LdDiscoStopFn
  lookup*: LdDiscoLookupFn
  randomLookup*: LdDiscoRandomLookupFn
  freePeerList*: LdDiscoFreePeerListFn
  startAdvertising*: LdDiscoStartAdvertisingFn
  stopAdvertising*: LdDiscoKeyFn
  registerInterest*: LdDiscoKeyFn
  unregisterInterest*: LdDiscoKeyFn
  addBootstrapEntries*: LdDiscoAddBootstrapEntriesFn

proc validate*(plugin: ServiceDiscoveryPlugin): Result[void, string] =
  ## Every entry point must be present; a plugin that cannot support a verb
  ## installs one that returns LD_DISCO_ERROR.
  if plugin.abiVersion != LdDiscoAbiVersion:
    return err(
      "service discovery plugin: ABI version mismatch, expected " & $LdDiscoAbiVersion &
        " got " & $plugin.abiVersion
    )
  if plugin.start.isNil() or plugin.stop.isNil() or plugin.lookup.isNil() or
      plugin.randomLookup.isNil() or plugin.freePeerList.isNil() or
      plugin.startAdvertising.isNil() or plugin.stopAdvertising.isNil() or
      plugin.registerInterest.isNil() or plugin.unregisterInterest.isNil() or
      plugin.addBootstrapEntries.isNil():
    return err("service discovery plugin: missing entry point")
  ok()

# Installs (or replaces) the plugin backing ExternalServiceDiscovery.
# Provided by the backend instance; requested by the FFI entry point, so the
# library layer needs no handle on the instance.
RequestBroker:
  proc setServiceDiscoveryPlugin(
    plugin: ServiceDiscoveryPlugin
  ): Future[Result[void, string]] {.async.}

RequestBroker:
  proc clearServiceDiscoveryPlugin(): Future[Result[void, string]] {.async.}
