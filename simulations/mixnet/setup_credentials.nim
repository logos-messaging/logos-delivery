{.push raises: [].}

## Setup script to generate RLN credentials and register them with the external service.
##
## This script:
## 1. Generates credentials for each node (identified by peer ID)
## 2. Registers all credentials with the external RLN service (in parallel)
## 3. Saves individual keystores named by peer ID, using the service's leaf index
##
## Usage: nim c -r setup_credentials.nim

import std/[os, strformat, options, json, strutils], chronicles, chronos, results
import chronos/apps/http/[httpclient, httpcommon]

import
  mix_rln_spam_protection/credentials,
  mix_rln_spam_protection/types

const
  KeystorePassword = "mix-rln-password" # Must match protocol.nim
  DefaultUserMessageLimit = 100'u64 # Network-wide default rate limit
  SpammerUserMessageLimit = 3'u64 # Lower limit for spammer testing
  RlnServiceUrl = "http://127.0.0.1:3001"

  # Peer IDs derived from nodekeys in config files
  # config.toml:   nodekey = "f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a"
  # config1.toml:  nodekey = "09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684"
  # config2.toml:  nodekey = "ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e"
  # config3.toml:  nodekey = "42f96f29f2d6670938b0864aced65a332dcf5774103b4c44ec4d0ea4ef3c47d6"
  # config4.toml:  nodekey = "3ce887b3c34b7a92dd2868af33941ed1dbec4893b054572cd5078da09dd923d4"
  # chat2mix.sh:   nodekey = "cb6fe589db0e5d5b48f7e82d33093e4d9d35456f4aaffc2322c473a173b2ac49"
  # chat2mix1.sh:  nodekey = "35eace7ccb246f20c487e05015ca77273d8ecaed0ed683de3d39bf4f69336feb"

  # Node info: (peerId, userMessageLimit)
  NodeConfigs = [
    ("16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o", DefaultUserMessageLimit),
      # config.toml (service node)
    ("16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF", DefaultUserMessageLimit),
      # config1.toml (mix node 1)
    ("16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA", DefaultUserMessageLimit),
      # config2.toml (mix node 2)
    ("16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f", DefaultUserMessageLimit),
      # config3.toml (mix node 3)
    ("16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu", DefaultUserMessageLimit),
      # config4.toml (mix node 4)
    ("16Uiu2HAm1QxSjNvNbsT2xtLjRGAsBLVztsJiTHr9a3EK96717hpj", DefaultUserMessageLimit),
      # chat2mix client 1
    ("16Uiu2HAmC9h26U1C83FJ5xpE32ghqya8CaZHX1Y7qpfHNnRABscN", DefaultUserMessageLimit),
      # chat2mix client 2
  ]

proc registerWithService(
    session: HttpSessionRef,
    address: HttpAddress,
    idCommitment: IDCommitment,
    rateLimit: uint64,
    reqId: int,
): Future[int] {.async.} =
  ## Register a credential with the external RLN service.
  ## Returns the leaf index assigned by the service.
  let commitmentHex = "0x" & idCommitment.toHex()
  let body = $(%*{
    "jsonrpc": "2.0",
    "method": "rln_register",
    "params": [commitmentHex, rateLimit],
    "id": reqId,
  })

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
    let parsed = parseJson(cast[string](resBytes))

    if parsed.hasKey("error"):
      raise newException(CatchableError, "Service error: " & $parsed["error"])

    return parsed["result"]["leaf_index"].getInt()
  finally:
    if req != nil:
      await req.closeWait()
    if res != nil:
      await res.closeWait()

proc setupCredentials() {.async.} =
  ## Generate credentials, register with external service in parallel, save keystores.

  echo "=== RLN Credentials Setup ==="
  echo "Generating credentials for ", NodeConfigs.len, " nodes...\n"

  # Generate credentials for all nodes
  var allCredentials:
    seq[tuple[peerId: string, cred: IdentityCredential, rateLimit: uint64]]
  for (peerId, rateLimit) in NodeConfigs:
    let cred = generateCredentials().valueOr:
      echo "Failed to generate credentials for ", peerId, ": ", error
      quit(1)

    allCredentials.add((peerId: peerId, cred: cred, rateLimit: rateLimit))
    echo "Generated credentials for ", peerId
    echo "  idCommitment: ", cred.idCommitment.toHex()[0 .. 15], "..."
    echo "  userMessageLimit: ", rateLimit

  echo ""

  # Register all credentials with the external RLN service in parallel
  echo "Registering all credentials with external RLN service at ", RlnServiceUrl, " (parallel)..."
  let session = HttpSessionRef.new()
  let address = session.getAddress(RlnServiceUrl).valueOr:
    echo "FATAL: Invalid RLN service URL: ", RlnServiceUrl
    quit(1)

  var futures: seq[Future[int]]
  for i, entry in allCredentials:
    futures.add(registerWithService(
      session, address, entry.cred.idCommitment, entry.rateLimit, i + 1
    ))

  var serviceIndices = newSeq[int](futures.len)
  try:
    await allFutures(futures)
    for i, fut in futures:
      if fut.failed:
        raise fut.error
      serviceIndices[i] = fut.read()
      echo "  Registered ",
        allCredentials[i].peerId, " at service index ", serviceIndices[i],
        " (limit: ", allCredentials[i].rateLimit, ")"
  except CatchableError as e:
    echo "FATAL: Failed to register with external service: ", e.msg
    echo "  The external RLN service must be running at ", RlnServiceUrl
    quit(1)

  await session.closeWait()

  echo ""

  # Save each credential to a keystore file using the service's leaf index
  echo "Saving keystores..."
  for i, entry in allCredentials:
    let keystorePath = &"rln_keystore_{entry.peerId}.json"
    let membershipIndex = MembershipIndex(serviceIndices[i])

    let saveResult = saveKeystore(
      entry.cred,
      KeystorePassword,
      keystorePath,
      some(membershipIndex),
      some(entry.rateLimit),
    )
    if saveResult.isErr:
      echo "Failed to save keystore for ", entry.peerId, ": ", saveResult.error
      quit(1)
    echo "  Saved: ", keystorePath, " (index: ", membershipIndex, ", limit: ", entry.rateLimit, ")"

  echo ""
  echo "=== Setup Complete ==="
  echo "  Keystores: rln_keystore_{peerId}.json"
  echo "  Password: ", KeystorePassword
  echo "  Default rate limit: ", DefaultUserMessageLimit

when isMainModule:
  waitFor setupCredentials()
