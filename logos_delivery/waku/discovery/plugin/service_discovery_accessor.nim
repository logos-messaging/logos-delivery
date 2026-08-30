{.push raises: [].}

## Accessor for an external service-discovery plugin: the Nim mirror of
## `library/logosdelivery_service_discovery.h` (the plugin ABI), the guarded
## slot the installed vtable lives in, and the brokers that surround it.
##
## Two broker lanes meet here, deliberately:
##
## * **Registration** rides a plain single-thread RequestBroker, so it is
##   served on the node's own thread and the backend can simply keep the
##   vtable as instance state. It could not travel any other way: the struct
##   is full of `pointer`/proc fields, which the (mt) codec rejects at compile
##   time. The worker receives it as its thread argument instead.
## * **Calls** ride `(mt)` RequestBrokers whose providers live on the worker
##   thread. Their payloads are plain Nim types, so results are marshalled
##   onto the caller's heap and the node's event loop only ever awaits.

import brokers/broker_context
import chronos, results
import brokers/request_broker
import logos_delivery/waku/discovery/peer_discovery_interface

export request_broker

const
  LdDiscoAbiVersion* = 1'u32
  LdDiscoOk* = 0.cint
  LdDiscoError* = 1.cint
  LdDiscoErrBufLen* = 512
  DefaultPluginRequestTimeout* = chronos.seconds(30)

type
  LdDiscoStartFn* = proc(pluginCtx: pointer, errBuf: cstring, errBufLen: csize_t): cint {.
    cdecl, gcsafe, raises: []
  .}

  LdDiscoStopFn* = LdDiscoStartFn

  LdDiscoLookupFn* = proc(
    pluginCtx: pointer,
    key: cstring,
    limit: int64,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): cint {.cdecl, gcsafe, raises: [].}

  LdDiscoRandomLookupFn* = proc(
    pluginCtx: pointer, outJson: ptr cstring, errBuf: cstring, errBufLen: csize_t
  ): cint {.cdecl, gcsafe, raises: [].}

  LdDiscoFreeStringFn* =
    proc(pluginCtx: pointer, s: cstring) {.cdecl, gcsafe, raises: [].}

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
  requestTimeoutMs*: uint32
    ## How long a caller waits for one verb; 0 selects
    ## `DefaultPluginRequestTimeout`. Owned by the plugin because only it
    ## knows how slow its operations are.
  start*: LdDiscoStartFn
  stop*: LdDiscoStopFn
  lookup*: LdDiscoLookupFn
  randomLookup*: LdDiscoRandomLookupFn
  freeString*: LdDiscoFreeStringFn
  startAdvertising*: LdDiscoStartAdvertisingFn
  stopAdvertising*: LdDiscoKeyFn
  registerInterest*: LdDiscoKeyFn
  unregisterInterest*: LdDiscoKeyFn
  addBootstrapEntries*: LdDiscoAddBootstrapEntriesFn

proc requestTimeout*(plugin: ServiceDiscoveryPlugin): Duration =
  if plugin.requestTimeoutMs == 0:
    DefaultPluginRequestTimeout
  else:
    chronos.milliseconds(plugin.requestTimeoutMs.int64)

proc validate*(plugin: ServiceDiscoveryPlugin): Result[void, string] =
  ## Every entry point must be present; a plugin that cannot support a verb
  ## installs one that returns LD_DISCO_ERROR.
  if plugin.abiVersion != LdDiscoAbiVersion:
    return err(
      "service discovery plugin: ABI version mismatch, expected " & $LdDiscoAbiVersion &
        " got " & $plugin.abiVersion
    )
  if plugin.start.isNil() or plugin.stop.isNil() or plugin.lookup.isNil() or
      plugin.randomLookup.isNil() or plugin.freeString.isNil() or
      plugin.startAdvertising.isNil() or plugin.stopAdvertising.isNil() or
      plugin.registerInterest.isNil() or plugin.unregisterInterest.isNil() or
      plugin.addBootstrapEntries.isNil():
    return err("service discovery plugin: missing entry point")
  ok()

# --- registration (single-thread lane) ---

# Installs (or replaces) the plugin backing ExternalServiceDiscovery, which
# keeps it as instance state. Provided by the backend instance; requested by
# the FFI entry point, so the library layer needs no handle on the instance.
RequestBroker:
  proc setServiceDiscoveryPlugin(
    plugin: ServiceDiscoveryPlugin
  ): Future[Result[void, string]] {.async.}

RequestBroker:
  proc clearServiceDiscoveryPlugin(): Future[Result[void, string]] {.async.}

# --- calls (mt lane: providers live on the discovery worker thread) ---
#
# One broker per plugin entry point: typed arguments, typed results, no op
# codes. The (mt) codec marshals payloads onto the caller's heap, so the node
# loop only ever awaits.

RequestBroker(mt):
  proc pluginStart(): Future[Result[void, string]] {.async.}

RequestBroker(mt):
  proc pluginStop(): Future[Result[void, string]] {.async.}

RequestBroker(mt):
  proc pluginLookup(
    key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.}

RequestBroker(mt):
  proc pluginRandomLookup(): Future[Result[seq[DiscoveredPeer], string]] {.async.}

RequestBroker(mt):
  proc pluginStartAdvertising(
    key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.}

RequestBroker(mt):
  proc pluginStopAdvertising(key: string): Future[Result[void, string]] {.async.}

RequestBroker(mt):
  proc pluginRegisterInterest(key: string): Future[Result[void, string]] {.async.}

RequestBroker(mt):
  proc pluginUnregisterInterest(key: string): Future[Result[void, string]] {.async.}

RequestBroker(mt):
  proc pluginAddBootstrapEntries(
    entries: seq[string]
  ): Future[Result[void, string]] {.async.}
