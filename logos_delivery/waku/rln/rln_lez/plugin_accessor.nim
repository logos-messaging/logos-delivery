{.push raises: [].}

## Accessor for the external RLN plugin: the Nim mirror of
## `library/liblogosdelivery_rln.h` (the plugin ABI) and the brokers that
## surround it.
##
## Two broker lanes meet here, deliberately:
##
## * **Registration** rides a plain single-thread RequestBroker: the vtable is
##   full of proc fields, which the (mt) codec rejects at compile time, so it
##   travels by address through the FFI entry point and reaches the workers as
##   their thread argument.
## * **Calls** ride `(mt)` RequestBrokers whose providers live on the per-verb
##   worker threads (`./plugin_worker`). Payloads are strings and scalars;
##   replies are the module's raw JSON — dialect decoding stays with the
##   caller (`./transport`).
##
## Every call payload carries the requester's absolute deadline as chronos
## `Moment` nanoseconds: the (mt) queue does not drop a request whose
## requester timed out, so providers check the deadline before touching the
## vtable and pass the remaining budget as the plugin's `timeout_ms`.

import chronos, results
import brokers/request_broker

export request_broker

const
  LdRlnPluginAbiVersion* = 1'u32
  LdRlnOk* = 0'i32
  LdRlnNotReady* = 1'i32
  LdRlnTimeout* = 2'i32
  LdRlnInternal* = 3'i32
  LdRlnErrBufLen* = 512

type
  LdRlnStartFn* = proc(
    pluginCtx: pointer,
    configJson: cstring,
    timeoutMs: uint32,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): int32 {.cdecl, gcsafe, raises: [].}

  LdRlnStopFn* = proc(
    pluginCtx: pointer,
    timeoutMs: uint32,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): int32 {.cdecl, gcsafe, raises: [].}

  LdRlnRegisterMembershipFn* = proc(
    pluginCtx: pointer,
    registryId, rlnIdentifier, optionsJson: cstring,
    timeoutMs: uint32,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): int32 {.cdecl, gcsafe, raises: [].}

  LdRlnGetMembershipStateFn* = proc(
    pluginCtx: pointer,
    registryId, rlnIdentifier: cstring,
    timeoutMs: uint32,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): int32 {.cdecl, gcsafe, raises: [].}

  LdRlnGetEpochQuotaFn* = proc(
    pluginCtx: pointer,
    registryId, rlnIdentifier: cstring,
    timestamp: uint64,
    timeoutMs: uint32,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): int32 {.cdecl, gcsafe, raises: [].}

  LdRlnGenerateProofFn* = proc(
    pluginCtx: pointer,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    timeoutMs: uint32,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): int32 {.cdecl, gcsafe, raises: [].}

  LdRlnValidateProofFn* = proc(
    pluginCtx: pointer,
    registryId, rlnIdentifier, signalHex: cstring,
    timestamp: uint64,
    proofJson: cstring,
    timeoutMs: uint32,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
  ): int32 {.cdecl, gcsafe, raises: [].}

  LdRlnFreeStringFn* =
    proc(pluginCtx: pointer, s: cstring) {.cdecl, gcsafe, raises: [].}

type RlnPlugin* = object
  ## Layout-compatible with `LdRlnPlugin`: field-for-field, which is the whole
  ## of what the C boundary needs. It is never passed to or from a C function
  ## — the entry point takes the struct's address and derefs it — so no
  ## calling-convention pragma applies here.
  abiVersion*: uint32
  pluginCtx*: pointer
  start*: LdRlnStartFn
  stop*: LdRlnStopFn
  registerMembership*: LdRlnRegisterMembershipFn
  getMembershipState*: LdRlnGetMembershipStateFn
  getEpochQuota*: LdRlnGetEpochQuotaFn
  generateProof*: LdRlnGenerateProofFn
  validateProof*: LdRlnValidateProofFn
  freeString*: LdRlnFreeStringFn

proc validate*(plugin: RlnPlugin): Result[void, string] =
  ## Every entry point must be present; a plugin that cannot support a verb
  ## installs one that returns LD_RLN_INTERNAL.
  if plugin.abiVersion != LdRlnPluginAbiVersion:
    return err(
      "rln plugin: ABI version mismatch, expected " & $LdRlnPluginAbiVersion &
        " got " & $plugin.abiVersion
    )
  if plugin.start.isNil() or plugin.stop.isNil() or plugin.registerMembership.isNil() or
      plugin.getMembershipState.isNil() or plugin.getEpochQuota.isNil() or
      plugin.generateProof.isNil() or plugin.validateProof.isNil() or
      plugin.freeString.isNil():
    return err("rln plugin: missing entry point")
  ok()

# --- registration (single-thread lane) ---

# Installs (or replaces) the plugin. Provided by the lez backend, which
# validates the vtable and spawns/joins the per-verb workers; requested by the
# FFI entry point, so the library layer needs no handle on the instance.
RequestBroker:
  proc setRlnPlugin(plugin: RlnPlugin): Future[Result[void, string]] {.async.}

RequestBroker:
  proc clearRlnPlugin(): Future[Result[void, string]] {.async.}

# --- calls ((mt) lane: one broker per verb, provider on that verb's worker) ---

RequestBroker(mt):
  proc pluginRlnStart(
    configJson: string, deadlineNs: int64
  ): Future[Result[string, string]] {.async.}

RequestBroker(mt):
  proc pluginRlnStop(deadlineNs: int64): Future[Result[string, string]] {.async.}

RequestBroker(mt):
  proc pluginRlnRegister(
    registryId: string, rlnIdentifier: string, optionsJson: string, deadlineNs: int64
  ): Future[Result[string, string]] {.async.}

RequestBroker(mt):
  proc pluginRlnGetState(
    registryId: string, rlnIdentifier: string, deadlineNs: int64
  ): Future[Result[string, string]] {.async.}

RequestBroker(mt):
  proc pluginRlnGetQuota(
    registryId: string, rlnIdentifier: string, timestamp: uint64, deadlineNs: int64
  ): Future[Result[string, string]] {.async.}

RequestBroker(mt):
  proc pluginRlnGenerate(
    registryId: string,
    rlnIdentifier: string,
    signalHex: string,
    timestamp: uint64,
    deadlineNs: int64,
  ): Future[Result[string, string]] {.async.}

RequestBroker(mt):
  proc pluginRlnValidate(
    registryId: string,
    rlnIdentifier: string,
    signalHex: string,
    timestamp: uint64,
    proofJson: string,
    deadlineNs: int64,
  ): Future[Result[string, string]] {.async.}
