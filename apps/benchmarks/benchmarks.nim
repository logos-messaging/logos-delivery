import
  std/[strutils, times, sequtils, osproc], math, results, options, testutils/unittests

import
  logos_delivery/waku/[
    waku_rln/protocol_types,
    waku_rln/bindings,
    waku_rln,
    waku_rln/conversion_utils,
    waku_rln/group_manager/on_chain/group_manager,
  ],
  tests/waku_rln/utils_onchain

proc benchmark(
    manager: OnChainGroupManager, registerCount: int, messageLimit: int
): Future[string] {.async, gcsafe.} =
  # Register a new member so that we can later generate proofs
  let idCredentials = generateCredentials(registerCount)

  var start_time = getTime()
  for i in 0 .. registerCount - 1:
    (await manager.register(idCredentials[i], UserMessageLimit(messageLimit + 1))).isOkOr:
      assert false, "register failed: " & error

    info "registration finished",
      iter = i, elapsed_ms = (getTime() - start_time).inMilliseconds

  discard await manager.updateRoots()
  manager.merkleProofCache = (await manager.fetchMerkleProofElements()).valueOr:
    error "Failed to fetch Merkle proof", error = error
    quit(QuitFailure)

  let epoch = default(Epoch)
  info "epoch in bytes", epochHex = epoch.inHex()
  let data: seq[byte] = newSeq[byte](1024)

  var proofGenTimes: seq[times.Duration] = @[]
  var proofVerTimes: seq[times.Duration] = @[]

  start_time = getTime()
  for i in 1 .. messageLimit:
    var generate_time = getTime()
    let proof = (await manager.generateProof(data, epoch, MessageId(i.uint8))).valueOr:
      raiseAssert $error
    proofGenTimes.add(getTime() - generate_time)

    let verify_time = getTime()
    discard manager.verifyProof(data, proof).valueOr:
      raiseAssert $error
    proofVerTimes.add(getTime() - verify_time)
    info "iteration finished",
      iter = i, elapsed_ms = (getTime() - start_time).inMilliseconds

  proc fmtMs(d: times.Duration): string =
    formatFloat(d.inNanoseconds.float / 1_000_000.0, ffDecimal, 3) & " ms"

  let avgGen = sum(proofGenTimes) div len(proofGenTimes)
  let avgVer = sum(proofVerTimes) div len(proofVerTimes)
  echo "Proof generation   (avg/min/max): ",
    fmtMs(avgGen), " / ", fmtMs(min(proofGenTimes)), " / ", fmtMs(max(proofGenTimes))
  echo "Proof verification (avg/min/max): ",
    fmtMs(avgVer), " / ", fmtMs(min(proofVerTimes)), " / ", fmtMs(max(proofVerTimes))

proc main() =
  # Start a local Ethereum JSON-RPC (Anvil) so that the group-manager setup can connect.
  let anvilProc = runAnvil()
  defer:
    stopAnvil(anvilProc)

  # Set up an On-chain group manager (includes contract deployment)
  let manager = waitFor setupOnchainGroupManager()
  (waitFor manager.init()).isOkOr:
    raiseAssert $error

  discard waitFor benchmark(manager, 200, 20)

when isMainModule:
  main()
