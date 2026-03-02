{.push raises: [].}

## RLN client: request-response delivery from C++ RLN module via registered fetcher.
##
## The C++ delivery module registers an RLN fetcher function pointer at startup.
## Nim calls the fetcher to get roots/proofs from the RLN module on demand.
## Callback factories are used by protocol.nim when wiring up spam protection.

import std/[json, strutils, locks]
import chronos
import results
import chronicles
import mix_rln_spam_protection/types

logScope:
  topics = "waku mix rln-client"

type
  RlnFetchCallback* = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].}
  RlnFetcherFunc* = proc(
    methodName: cstring, params: cstring,
    callback: RlnFetchCallback,
    callbackData: pointer, fetcherData: pointer
  ): cint {.cdecl, gcsafe, raises: [].}

var
  rlnFetcherLock: Lock
  rlnFetcher: RlnFetcherFunc
  rlnFetcherData: pointer
  rlnConfigAccountId: string
  rlnLeafIndex: int = -1
  cachedRootsJson: string
  cachedProofJson: string

rlnFetcherLock.initLock()

proc setRlnFetcher*(fetcher: RlnFetcherFunc, fetcherData: pointer) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnFetcher = fetcher
    rlnFetcherData = fetcherData
    rlnFetcherLock.release()

proc setRlnConfig*(configAccountId: string, leafIndex: int) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnConfigAccountId = configAccountId
    rlnLeafIndex = leafIndex
    rlnFetcherLock.release()

proc getRlnConfig*(): (string, int) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = (rlnConfigAccountId, rlnLeafIndex)
    rlnFetcherLock.release()

proc pushRoots*(rootsJson: string) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    cachedRootsJson = rootsJson
    rlnFetcherLock.release()
    trace "Received roots via event push", len = rootsJson.len

proc pushProof*(proofJson: string) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    cachedProofJson = proofJson
    rlnFetcherLock.release()
    trace "Received proof via event push", len = proofJson.len

proc getCachedRoots(): string {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = cachedRootsJson
    rlnFetcherLock.release()

proc getCachedProof(): string {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = cachedProofJson
    rlnFetcherLock.release()

type FetchResult = object
  json: string
  errMsg: string
  success: bool

proc callRlnFetcher(methodName: string, params: string): Result[string, string] {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    let fetcher = rlnFetcher
    let data = rlnFetcherData
    rlnFetcherLock.release()

    if fetcher.isNil:
      return err("RLN fetcher not registered")

    var fetchResult: FetchResult

    let cb: RlnFetchCallback = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      let res = cast[ptr FetchResult](userData)
      if callerRet == 0 and not msg.isNil and len > 0:
        res[].json = newString(len.int)
        copyMem(addr res[].json[0], msg, len.int)
        res[].success = true
      elif not msg.isNil and len > 0:
        res[].errMsg = newString(len.int)
        copyMem(addr res[].errMsg[0], msg, len.int)
        res[].success = false
      else:
        res[].success = (callerRet == 0)

    let ret = fetcher(methodName.cstring, params.cstring, cb, addr fetchResult, data)
    if ret != 0 or not fetchResult.success:
      if fetchResult.errMsg.len > 0:
        return err(fetchResult.errMsg)
      return err("RLN fetcher returned error code: " & $ret)
    if fetchResult.json.len == 0:
      return err("RLN fetcher returned empty response")
    return ok(fetchResult.json)

proc hexToBytes32(hex: string): Result[array[32, byte], string] =
  var h = hex
  if h.startsWith("0x") or h.startsWith("0X"):
    h = h[2 .. ^1]
  if h.len != 64:
    return err("Expected 64 hex chars, got " & $h.len)
  var output: array[32, byte]
  for i in 0 ..< 32:
    try:
      output[i] = byte(parseHexInt(h[i * 2 .. i * 2 + 1]))
    except ValueError:
      return err("Invalid hex at position " & $i)
  ok(output)

proc parseRootsJson*(snapshot: string): RlnResult[seq[MerkleNode]] =
  if snapshot.len == 0:
    return err("No roots data")
  try:
    let parsed = parseJson(snapshot)
    var roots: seq[MerkleNode]
    for elem in parsed:
      let root = hexToBytes32(elem.getStr()).valueOr:
        return err("Invalid root hex: " & error)
      roots.add(MerkleNode(root))
    return ok(roots)
  except CatchableError as e:
    return err("Failed to parse roots: " & e.msg)

proc parseExternalProof(snapshot: string): Result[ExternalMerkleProof, string] =
  if snapshot.len == 0:
    return err("No merkle proof data")
  try:
    let parsed = parseJson(snapshot)
    let root = hexToBytes32(parsed["root"].getStr()).valueOr:
      return err("Invalid root hex: " & error)
    var pathElements: seq[byte]
    for elem in parsed["path_elements"]:
      let elemBytes = hexToBytes32(elem.getStr()).valueOr:
        return err("Invalid pathElement hex: " & error)
      for b in elemBytes:
        pathElements.add(b)
    var identityPathIndex: seq[byte]
    for idx in parsed["path_indices"]:
      identityPathIndex.add(byte(idx.getInt()))
    ok(ExternalMerkleProof(
      pathElements: pathElements,
      identityPathIndex: identityPathIndex,
      root: MerkleNode(root),
    ))
  except CatchableError as e:
    err("Failed to parse proof: " & e.msg)

proc makeFetchLatestRoots*(): FetchLatestRootsCallback =
  return proc(): Future[RlnResult[seq[MerkleNode]]] {.async, gcsafe, raises: [].} =
    let cached = getCachedRoots()
    if cached.len > 0:
      let res = parseRootsJson(cached)
      if res.isOk:
        trace "Using cached roots from event push", count = res.get().len
      return res
    let (configAccount, _) = getRlnConfig()
    if configAccount.len == 0:
      return err("RLN config not set")
    let rootsJson = callRlnFetcher("get_valid_roots", configAccount)
    if rootsJson.isErr:
      return err(rootsJson.error)
    let res = parseRootsJson(rootsJson.get())
    if res.isOk:
      trace "Fetched roots from RLN module via fetcher", count = res.get().len
    return res

proc makeFetchMerkleProof*(): FetchMerkleProofCallback =
  return proc(
      index: MembershipIndex
  ): Future[RlnResult[ExternalMerkleProof]] {.async, gcsafe, raises: [].} =
    let cached = getCachedProof()
    if cached.len > 0:
      let res = parseExternalProof(cached)
      if res.isOk:
        trace "Using cached proof from event push", index = index
      return res
    let (configAccount, leafIndex) = getRlnConfig()
    if configAccount.len == 0:
      return err("RLN config not set")
    let params = configAccount & "," & $leafIndex
    let proofJson = callRlnFetcher("get_merkle_proofs", params)
    if proofJson.isErr:
      return err(proofJson.error)
    let res = parseExternalProof(proofJson.get())
    if res.isOk:
      trace "Fetched merkle proof from RLN module via fetcher", index = index
    return res

{.pop.}
