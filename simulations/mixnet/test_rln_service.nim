## Quick smoke test for the external RLN JSON-RPC service.
##
## Usage: nim c -r test_rln_service.nim [http://127.0.0.1:3001]

import std/[httpclient, json, os, strutils]

const DefaultUrl = "http://127.0.0.1:3001"

proc jsonRpc(client: HttpClient, url, methodName: string,
             params: JsonNode = newJArray()): JsonNode =
  let body = %*{
    "jsonrpc": "2.0",
    "method": methodName,
    "params": params,
    "id": 1
  }
  let resp = client.request(url, httpMethod = HttpPost,
                            body = $body,
                            headers = newHttpHeaders({"Content-Type": "application/json"}))
  let parsed = parseJson(resp.body)
  if parsed.hasKey("error"):
    echo "  ERROR: ", parsed["error"]
    return nil
  return parsed["result"]

proc main() =
  let url = if paramCount() >= 1: paramStr(1) else: DefaultUrl
  echo "Testing RLN service at ", url
  let client = newHttpClient()

  # 1. Get root
  echo "\n--- rln_getRoot ---"
  let root = client.jsonRpc(url, "rln_getRoot")
  if root != nil:
    echo "  root: ", root.getStr()

  # 2. Register a dummy identity commitment
  echo "\n--- rln_register ---"
  # 32-byte hex commitment (64 hex chars) — just a test value
  let testCommitment = "0x" & "ab".repeat(32)
  let testLimit = 100
  let regResult = client.jsonRpc(url, "rln_register",
    %*[testCommitment, testLimit])
  if regResult != nil:
    echo "  result: ", regResult

  # 3. Get root again (should have changed after registration)
  echo "\n--- rln_getRoot (after register) ---"
  let root2 = client.jsonRpc(url, "rln_getRoot")
  if root2 != nil:
    echo "  root: ", root2.getStr()
    if root != nil:
      echo "  changed: ", root.getStr() != root2.getStr()

  # 4. Get merkle proof for index 0
  echo "\n--- rln_getMerkleProof(0) ---"
  let proof = client.jsonRpc(url, "rln_getMerkleProof", %*[0])
  if proof != nil:
    if proof.kind == JObject:
      for key, val in proof.pairs:
        let s = $val
        if s.len > 200:
          echo "  ", key, ": ", s[0..196], "..."
        else:
          echo "  ", key, ": ", s
    else:
      echo "  result: ", proof

  echo "\nDone."

main()
