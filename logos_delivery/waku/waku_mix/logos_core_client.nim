{.push raises: [].}

## Mix RLN client: fetches roots/proofs from logos-core via the C++ RLN module.
## The C++ delivery module registers an RLN fetcher at startup; event-push
## caching avoids round-trips on the hot path.

import std/[json, strutils, locks, options]
import chronos, chronos/threadsync
import results
import chronicles
import mix_rln_spam_protection/group_manager {.all.}
import mix_rln_spam_protection/types {.all.}
import mix_rln_spam_protection/rln_interface
import mix_rln_spam_protection/onchain_group_manager

export onchain_group_manager.ExternalMerkleProof

logScope:
  topics = "waku mix rln-lez-client"

type
  FetchLatestRootsCallback* =
    proc(): Future[Result[seq[MerkleNode], string]] {.gcsafe, raises: [].}
  FetchMerkleProofCallback* =
    proc(index: MembershipIndex): Future[Result[ExternalMerkleProof, string]] {.gcsafe, raises: [].}

type
  RlnFetchCallback* = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].}
  RlnFetcherFunc* = proc(
    methodName: cstring, params: cstring,
    callback: RlnFetchCallback,
    callbackData: pointer, fetcherData: pointer
  ): cint {.cdecl, gcsafe, raises: [].}

const RLN_CONFIG_ACCOUNT_ID_CAP = 64
  ## Max bytes for the base58-encoded config account ID (real values ≤44
  ## chars). Sized as a value-type buffer so cross-thread access doesn't
  ## go through Nim's heap/GC — see rlnConfigAccountIdBuf below.

var
  rlnFetcherLock: Lock
  rlnFetcher: RlnFetcherFunc
  rlnFetcherData: pointer
  ## Fixed-size byte buffer + length, not a Nim string: the FFI worker
  ## thread reads concurrently with main-thread writes, and a heap string
  ## here SIGSEGVs under testnet load (GC collects the old value mid-read
  ## during the 200-500ms HTTPS fetchRoots awaits).
  rlnConfigAccountIdBuf: array[RLN_CONFIG_ACCOUNT_ID_CAP, char]
  rlnConfigAccountIdLen: int = 0
  rlnLeafIndex: int = -1
  rlnIdentitySecretHash: string
  rlnGroupManager: pointer
    ## OnchainLEZGroupManager ref erased to `pointer` so this lock-protected
    ## global is not tracked by Nim's GC: setGroupManagerRef may be invoked
    ## from a thread distinct from the one that later runs setRlnIdentity,
    ## and storing a ref in a cross-thread global risks GC interference.
    ## Cast back to OnchainLEZGroupManager in setRlnIdentity to attach credentials.
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
    let n = min(configAccountId.len, RLN_CONFIG_ACCOUNT_ID_CAP)
    for i in 0 ..< n:
      rlnConfigAccountIdBuf[i] = configAccountId[i]
    rlnConfigAccountIdLen = n
    rlnLeafIndex = leafIndex
    rlnFetcherLock.release()

proc setGroupManagerRef*(lezGm: OnchainLEZGroupManager) {.gcsafe.} =
  ## Store the group manager so setRlnIdentity can attach credentials later.
  ## Erases the typed ref to `pointer` internally so the lock-protected global
  ## stays outside Nim's cross-thread GC tracking (see rlnGroupManager).
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnGroupManager = cast[pointer](lezGm)
    rlnFetcherLock.release()

proc setRlnIdentity*(idSecretHashHex: string) {.gcsafe.} =
  ## Regenerate the full credential via membershipKeyGen(seed=idSecretHash)
  ## and attach it to the group manager. Called by the C++ plugin after
  ## selfRegisterRln completes.
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    rlnIdentitySecretHash = idSecretHashHex
    let gm = rlnGroupManager
    let leafIdx = rlnLeafIndex
    rlnFetcherLock.release()

    trace "Set mix RLN identity", hashPrefix = idSecretHashHex[0 .. min(7, idSecretHashHex.len - 1)]

    if not gm.isNil and idSecretHashHex.len == 64:
      var seedBytes: seq[byte]
      for i in 0 ..< 32:
        try:
          seedBytes.add(byte(parseHexInt(idSecretHashHex[i * 2 .. i * 2 + 1])))
        except ValueError:
          warn "Invalid hex in identity hash"
          return

      # Generate full credential using the same seed that selfRegisterRln used
      # via generate_identity. membershipKeyGen(seed) produces deterministic output.
      let cred = membershipKeyGen(seedBytes).valueOr:
        warn "Failed to regenerate full credential from seed", error = $error
        return

      let gmRef = cast[OnchainLEZGroupManager](gm)
      gmRef.credentials = some(cred)
      if leafIdx >= 0:
        gmRef.membershipIndex = some(types.MembershipIndex(leafIdx))
      info "Set full RLN identity on group manager",
        leafIndex = leafIdx,
        commitment = cred.idCommitment[0 .. 7].toHex() & "..."

proc getRlnIdentity*(): string {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    result = rlnIdentitySecretHash
    rlnFetcherLock.release()

proc getRlnConfig*(): (string, int) {.gcsafe.} =
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    let n = rlnConfigAccountIdLen
    let leafIdx = rlnLeafIndex
    var s = newString(n)
    for i in 0 ..< n:
      s[i] = rlnConfigAccountIdBuf[i]
    rlnFetcherLock.release()
    result = (s, leafIdx)

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

proc callRlnFetcher*(methodName: string, params: string): Result[string, string] {.gcsafe.} =
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

type ThreadArgs = object
  fetcher: RlnFetcherFunc
  fetcherData: pointer
  methodBuf: cstring
  paramsBuf: cstring
  res: ptr FetchResult
  sig: ThreadSignalPtr

proc fetcherThreadBody(args: ThreadArgs) {.thread.} =
  let cb: RlnFetchCallback = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
    let r = cast[ptr FetchResult](userData)
    if callerRet == 0 and not msg.isNil and len > 0:
      r[].json = newString(len.int)
      copyMem(addr r[].json[0], msg, len.int)
      r[].success = true
    elif not msg.isNil and len > 0:
      r[].errMsg = newString(len.int)
      copyMem(addr r[].errMsg[0], msg, len.int)
      r[].success = false
    else:
      r[].success = (callerRet == 0)

  discard args.fetcher(args.methodBuf, args.paramsBuf, cb, args.res, args.fetcherData)
  discard args.sig.fireSync()

proc callRlnFetcherAsync*(methodName: string, params: string): Future[Result[string, string]] {.async.} =
  ## Runs the fetcher on a dedicated thread so HTTPS blocking calls don't
  ## stall the chronos event loop.
  {.gcsafe.}:
    rlnFetcherLock.acquire()
    let fetcher = rlnFetcher
    let data = rlnFetcherData
    rlnFetcherLock.release()

    if fetcher.isNil:
      return err("RLN fetcher not registered")

    let signal = ThreadSignalPtr.new().valueOr:
      return err("failed to create thread signal")
    defer:
      discard signal.close()

    # Stable cross-thread copies — `methodName`/`params` live on the GC heap.
    # IMPORTANT: guard the unsafeAddr deref — `unsafeAddr s[0]` on an empty
    # Nim string is UB (the backing buffer can be nil), and SIGSEGVs at the
    # polling layer (e.g. get_valid_roots with no config yet). allocShared0
    # already zero-fills, so the copy is safely no-op when len is 0.
    var methodCopy = allocShared0(methodName.len + 1)
    var paramsCopy = allocShared0(params.len + 1)
    if methodName.len > 0:
      copyMem(methodCopy, unsafeAddr methodName[0], methodName.len)
    if params.len > 0:
      copyMem(paramsCopy, unsafeAddr params[0], params.len)
    defer:
      deallocShared(methodCopy)
      deallocShared(paramsCopy)

    var fetchRes: FetchResult
    var thread: Thread[ThreadArgs]

    createThread(thread, fetcherThreadBody,
      ThreadArgs(
        fetcher: fetcher,
        fetcherData: data,
        methodBuf: cast[cstring](methodCopy),
        paramsBuf: cast[cstring](paramsCopy),
        res: addr fetchRes,
        sig: signal,
      ))

    await signal.wait()
    joinThread(thread)

    if not fetchRes.success:
      if fetchRes.errMsg.len > 0:
        return err(fetchRes.errMsg)
      return err("RLN fetcher async call failed")
    if fetchRes.json.len == 0:
      return err("RLN fetcher returned empty response")
    return ok(fetchRes.json)

proc bytesToHexUpper*(bytes: openArray[byte]): string =
  ## Uppercase hex without "0x" prefix. LEZ JSON RPC accepts both cases;
  ## uppercase matches the existing register_member / is_member_registered
  ## payload format.
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(toHex(int(b), 2))

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

proc parseRootsJson*(snapshot: string): Result[seq[MerkleNode], string] =
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
    var validRoots: seq[MerkleNode]
    if parsed.hasKey("valid_roots"):
      for r in parsed["valid_roots"]:
        let rb = hexToBytes32(r.getStr()).valueOr:
          continue
        validRoots.add(MerkleNode(rb))
    ok(ExternalMerkleProof(
      pathElements: pathElements,
      identityPathIndex: identityPathIndex,
      root: MerkleNode(root),
      validRoots: validRoots,
    ))
  except CatchableError as e:
    err("Failed to parse proof: " & e.msg)

proc makeFetchLatestRoots*(): FetchLatestRootsCallback =
  return proc(): Future[Result[seq[MerkleNode], string]] {.async, gcsafe, raises: [].} =
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
  ): Future[Result[ExternalMerkleProof, string]] {.async, gcsafe, raises: [].} =
    let cached = getCachedProof()
    if cached.len > 0:
      let res = parseExternalProof(cached)
      if res.isOk:
        trace "Using cached proof from event push", index = index
      return res
    let (configAccount, _) = getRlnConfig()
    if configAccount.len == 0:
      return err("RLN config not set")
    let params = configAccount & "," & $index
    let proofJson = callRlnFetcher("get_merkle_proofs", params)
    if proofJson.isErr:
      return err(proofJson.error)
    return parseExternalProof(proofJson.get())

{.pop.}
