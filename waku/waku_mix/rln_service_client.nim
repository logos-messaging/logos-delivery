{.push raises: [].}

## JSON-RPC client for the external RLN Merkle proof service.
##
## Provides factory functions that create the callback procs expected by
## GroupManager (FetchLatestRootsCallback, FetchMerkleProofCallback).

import std/[json, strutils]
import chronos
import chronos/apps/http/[httpclient, httpcommon]
import results
import stew/byteutils
import chronicles

import mix_rln_spam_protection/types

logScope:
  topics = "waku mix rln-service"

# =============================================================================
# Helpers
# =============================================================================

proc jsonRpcCall(
    session: HttpSessionRef, address: HttpAddress, methodName: string,
    params: string = "[]",
): Future[JsonNode] {.async.} =
  ## Make a JSON-RPC call and return the result field.
  let body = """{"jsonrpc":"2.0","method":"""" & methodName &
      """","params":""" & params & ""","id":1}"""

  var req: HttpClientRequestRef = nil
  var res: HttpClientResponseRef = nil
  try:
    req = HttpClientRequestRef.post(
      session, address,
      body = body.toOpenArrayByte(0, body.len - 1),
      headers = @[("Content-Type", "application/json")],
    )
    res = await req.send()
    let resBytes = await res.getBodyBytes()
    let parsed = parseJson(string.fromBytes(resBytes))

    if parsed.hasKey("error"):
      let errMsg = $parsed["error"]
      raise newException(CatchableError, "JSON-RPC error: " & errMsg)

    if not parsed.hasKey("result"):
      raise newException(CatchableError, "JSON-RPC response missing 'result'")

    return parsed["result"]
  finally:
    if req != nil:
      await req.closeWait()
    if res != nil:
      await res.closeWait()

proc hexToBytes32(hex: string): RlnResult[array[32, byte]] =
  ## Parse a "0x..." hex string into a 32-byte array.
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

# =============================================================================
# Callback factories
# =============================================================================

proc makeFetchLatestRoots*(
    serviceUrl: string
): FetchLatestRootsCallback =
  ## Create a callback that fetches the latest valid Merkle roots from the
  ## RLN service via rln_getRoots. Returns 1–5 roots, newest first.
  let session = HttpSessionRef.new()
  let address = session.getAddress(serviceUrl)
  if address.isErr:
    warn "Invalid RLN service URL", url = serviceUrl, error = address.error
    return proc(): Future[RlnResult[seq[MerkleNode]]] {.async, gcsafe, raises: [].} =
      return err("Invalid RLN service URL: " & serviceUrl)

  let httpAddress = address.get()

  return proc(): Future[RlnResult[seq[MerkleNode]]] {.async, gcsafe, raises: [].} =
    try:
      let resultJson = await jsonRpcCall(session, httpAddress, "rln_getRoots")
      var roots: seq[MerkleNode]
      for elem in resultJson:
        let root = hexToBytes32(elem.getStr()).valueOr:
          return err("Invalid root hex: " & error)
        roots.add(MerkleNode(root))
      return ok(roots)
    except CatchableError as e:
      debug "Failed to fetch latest roots", error = e.msg
      return err("Failed to fetch roots: " & e.msg)

proc makeFetchMerkleProof*(
    serviceUrl: string
): FetchMerkleProofCallback =
  ## Create a callback that fetches a Merkle proof from the RLN service.
  let session = HttpSessionRef.new()
  let address = session.getAddress(serviceUrl)
  if address.isErr:
    warn "Invalid RLN service URL", url = serviceUrl, error = address.error
    return proc(
        index: MembershipIndex
    ): Future[RlnResult[ExternalMerkleProof]] {.async, gcsafe, raises: [].} =
      return err("Invalid RLN service URL: " & serviceUrl)

  let httpAddress = address.get()

  return proc(
      index: MembershipIndex
  ): Future[RlnResult[ExternalMerkleProof]] {.async, gcsafe, raises: [].} =
    try:
      let resultJson = await jsonRpcCall(
        session, httpAddress, "rln_getMerkleProof", "[" & $index & "]"
      )

      # Parse root
      let rootHex = resultJson["root"].getStr()
      let root = hexToBytes32(rootHex).valueOr:
        return err("Invalid root hex: " & error)

      # Parse pathElements: array of "0x..." hex strings -> concatenated bytes
      var pathElements: seq[byte]
      for elem in resultJson["pathElements"]:
        let elemBytes = hexToBytes32(elem.getStr()).valueOr:
          return err("Invalid pathElement hex: " & error)
        for b in elemBytes:
          pathElements.add(b)

      # Parse identityPathIndex: array of ints -> byte per level
      var identityPathIndex: seq[byte]
      for idx in resultJson["identityPathIndex"]:
        identityPathIndex.add(byte(idx.getInt()))

      return ok(ExternalMerkleProof(
        pathElements: pathElements,
        identityPathIndex: identityPathIndex,
        root: MerkleNode(root),
      ))
    except CatchableError as e:
      debug "Failed to fetch Merkle proof", index = index, error = e.msg
      return err("Failed to fetch Merkle proof: " & e.msg)

{.pop.}
