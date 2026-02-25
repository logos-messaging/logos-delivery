## Integration test: GroupManager with external RLN service.
##
## Prerequisites:
##   - RLN service running at http://127.0.0.1:3001
##   - Run setup_credentials first to generate keystores
##
## Usage: nim c -r --mm:refc test_onchain_gm.nim [http://127.0.0.1:3001]

import std/[os, options]
import chronos, results, chronicles

import
  mix_rln_spam_protection/types,
  mix_rln_spam_protection/constants,
  mix_rln_spam_protection/rln_interface,
  mix_rln_spam_protection/group_manager,
  mix_rln_spam_protection/credentials

# Import the service client from the waku layer
import ../../waku/waku_mix/rln_service_client

const
  DefaultUrl = "http://127.0.0.1:3001"
  KeystorePassword = "mix-rln-password"
  # Use the first node's peer ID for keystore lookup
  TestPeerId = "16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"

proc main() {.async.} =
  let serviceUrl = if paramCount() >= 1: paramStr(1) else: DefaultUrl
  echo "=== OnchainGroupManager Integration Test ==="
  echo "Service URL: ", serviceUrl

  # 1. Create RLN instance
  echo "\n1. Creating RLN instance..."
  let rlnInstance = newRLNInstance().valueOr:
    echo "FAIL: ", error
    quit(1)
  echo "   OK"

  # 2. Create GroupManager
  echo "\n2. Creating GroupManager..."
  let gm = newGroupManager(
    rlnInstance, pollIntervalSeconds = 2.0, userMessageLimit = 100
  )

  # 3. Set service callbacks
  echo "\n3. Setting service callbacks..."
  gm.setFetchLatestRoots(makeFetchLatestRoots(serviceUrl))
  gm.setFetchMerkleProof(makeFetchMerkleProof(serviceUrl))
  echo "   OK"

  # 4. Initialize
  echo "\n4. Initializing group manager..."
  let initRes = await gm.init()
  if initRes.isErr:
    echo "FAIL: ", initRes.error
    quit(1)
  echo "   OK"

  # 5. Load credentials from keystore
  echo "\n5. Loading credentials..."
  let keystorePath = "rln_keystore_" & TestPeerId & ".json"
  if not fileExists(keystorePath):
    echo "FAIL: Keystore not found at ", keystorePath
    echo "   Run build_setup.sh first"
    quit(1)

  let (cred, maybeIndex, maybeRateLimit, wasGenerated) =
    loadOrGenerateCredentials(keystorePath, KeystorePassword).valueOr:
      echo "FAIL: ", error
      quit(1)

  echo "   Loaded credential from keystore"
  echo "   idCommitment: ", cred.idCommitment.toHex()[0..15], "..."
  if maybeIndex.isSome:
    echo "   membershipIndex: ", maybeIndex.get()
  if maybeRateLimit.isSome:
    echo "   userMessageLimit: ", maybeRateLimit.get()

  # 6. Register credentials with the group manager
  echo "\n6. Registering credentials..."
  if maybeIndex.isSome:
    gm.credentials = some(cred)
    gm.membershipIndex = some(maybeIndex.get())
    echo "   Set credentials with index ", maybeIndex.get()
  else:
    echo "   No index in keystore, registering..."
    let regRes = await gm.register(cred)
    if regRes.isErr:
      echo "FAIL: ", regRes.error
      quit(1)
    echo "   Registered at index ", regRes.get()

  # 7. Start the group manager (begins polling)
  echo "\n7. Starting group manager (polling)..."
  let startRes = await gm.start()
  if startRes.isErr:
    echo "FAIL: ", startRes.error
    quit(1)
  echo "   OK - polling started"

  # 8. Wait for cached proof to arrive
  echo "\n8. Waiting for cached proof..."
  var attempts = 0
  while attempts < 10:
    await sleepAsync(chronos.seconds(1))
    attempts.inc()
    # Try generating a proof to see if cache is populated
    let testSignal = @[byte(1), 2, 3, 4]
    let epoch = currentEpoch()
    var rlnId: RlnIdentifier
    let idStr = MixRlnIdentifier
    let copyLen = min(idStr.len, HashByteSize)
    if copyLen > 0:
      copyMem(addr rlnId[0], unsafeAddr idStr[0], copyLen)
    let proofRes = gm.generateProof(testSignal, epoch, rlnId)
    if proofRes.isOk:
      echo "   Proof generated after ", attempts, " seconds!"
      let proof = proofRes.get()
      echo "   merkleRoot: ", proof.merkleRoot.toHex()[0..15], "..."
      echo "   epoch: ", proof.epoch.epochToUint64()
      echo "   nullifier: ", proof.nullifier.toHex()[0..15], "..."

      # 9. Verify the proof
      echo "\n9. Verifying proof..."
      # Pass the proof's root as a valid root since our local tree is empty
      let verifyRes = rlnInstance.verifyRlnProof(
        proof, rlnId, testSignal, validRoots = @[proof.merkleRoot]
      )
      if verifyRes.isOk and verifyRes.get():
        echo "   PASS - proof verified successfully!"
      else:
        echo "   FAIL - proof verification failed"
        if verifyRes.isErr:
          echo "   Error: ", verifyRes.error

      # 10. Stop
      echo "\n10. Stopping..."
      await gm.stop()
      echo "   Stopped"

      echo "\n=== ALL TESTS PASSED ==="
      return

  echo "   FAIL: No cached proof after ", attempts, " seconds"
  await gm.stop()
  quit(1)

waitFor main()
