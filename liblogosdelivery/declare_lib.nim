import ffi
import std/locks
import chronicles
import waku/factory/waku
import waku/waku_mix/logos_core_client

declareLibrary("logosdelivery")

var eventCallbackLock: Lock
initLock(eventCallbackLock)

template requireInitializedNode*(
    ctx: ptr FFIContext[Waku], opName: string, onError: untyped
) =
  if isNil(ctx):
    let errMsg {.inject.} = opName & " failed: invalid context"
    onError
  elif isNil(ctx.myLib) or isNil(ctx.myLib[]):
    let errMsg {.inject.} = opName & " failed: node is not initialized"
    onError

proc logosdelivery_set_event_callback(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.dynlib, exportc, cdecl.} =
  if isNil(ctx):
    echo "error: invalid context in logosdelivery_set_event_callback"
    return

  # prevent race conditions that might happen due incorrect usage.
  eventCallbackLock.acquire()
  defer:
    eventCallbackLock.release()

  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

proc logosdelivery_init(): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  when declared(setLogLevel):
    setLogLevel(LogLevel.WARN)
  return RET_OK

proc logosdelivery_set_rln_fetcher(
    ctx: ptr FFIContext[Waku], fetcher: RlnFetcherFunc, fetcherData: pointer
) {.dynlib, exportc, cdecl.} =
  if fetcher.isNil:
    echo "error: nil fetcher in logosdelivery_set_rln_fetcher"
    return
  setRlnFetcher(fetcher, fetcherData)

proc logosdelivery_set_rln_config(
    ctx: ptr FFIContext[Waku], configAccountId: cstring, leafIndex: cint
): cint {.dynlib, exportc, cdecl.} =
  if configAccountId.isNil:
    return RET_ERR
  setRlnConfig($configAccountId, leafIndex.int)
  return RET_OK

proc logosdelivery_push_roots(
    ctx: ptr FFIContext[Waku], rootsJson: cstring
) {.dynlib, exportc, cdecl.} =
  if rootsJson.isNil:
    return
  pushRoots($rootsJson)

proc logosdelivery_push_proof(
    ctx: ptr FFIContext[Waku], proofJson: cstring
) {.dynlib, exportc, cdecl.} =
  if proofJson.isNil:
    return
  pushProof($proofJson)

