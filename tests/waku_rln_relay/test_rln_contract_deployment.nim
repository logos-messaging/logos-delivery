{.used.}

{.push raises: [].}

import std/[options, os], results, testutils/unittests, chronos, web3

import
  waku/[
    waku_rln_relay,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain/group_manager,
  ],
  ./utils_onchain

suite "Token and RLN Contract Deployment":
  test "anvil should dump state to file on exit":
    # git will ignore this file, if the contract has been updated and the state file needs to be regenerated then this file can be renamed to replace the one in the repo (tests/waku_rln_relay/anvil_state/tests/waku_rln_relay/anvil_state/state-deployed-contracts-mint-and-approved.json)
    let testStateFile = some("tests/waku_rln_relay/anvil_state/anvil_state.ignore.json")
    let anvilProc = runAnvil(stateFile = testStateFile, dumpStateOnExit = true)
    let manager = waitFor setupOnchainGroupManager(deployContracts = true)

    stopAnvil(anvilProc)

    check:
      fileExists(testStateFile.get())

    #The test should still pass even if thie compression fails
    compressGzipFile(testStateFile.get(), testStateFile.get() & ".gz").isOkOr:
      error "Failed to compress state file", error = error
