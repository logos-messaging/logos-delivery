import libp2p/crypto/rng
{.used.}

{.push raises: [].}

import
  std/[net, options, os, osproc, streams, strutils, strformat],
  results,
  stew/byteutils,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  web3,
  web3/conversions,
  web3/eth_api_types,
  json_rpc/rpcclient,
  libp2p/crypto/crypto,
  eth/keys,
  results

import
  logos_delivery/waku/[
    waku_rln_relay,
    waku_rln_relay/protocol_types,
    waku_rln_relay/constants,
    waku_rln_relay/rln,
  ],
  ../testlib/common

const CHAIN_ID* = 1234'u256

# Cached Anvil state with pre-deployed contracts and a pre-funded/approved account.
const DEFAULT_ANVIL_STATE_PATH* =
  "tests/waku_rln_relay/anvil_state/state-deployed-contracts-mint-and-approved.json.gz"
const TOKEN_ADDRESS* = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
const WAKU_RLNV2_PROXY_ADDRESS* = "0x5fc8d32690cc91d4c39d9d3abcbd16989f875707"

proc generateCredentials*(): IdentityCredential =
  let credRes = membershipKeyGen()
  return credRes.get()

proc getRateCommitment*(
    idCredential: IdentityCredential, userMessageLimit: UserMessageLimit
): RlnRelayResult[RawRateCommitment] =
  return RateCommitment(
    idCommitment: idCredential.idCommitment, userMessageLimit: userMessageLimit
  ).toLeaf()

proc generateCredentials*(n: int): seq[IdentityCredential] =
  var credentials: seq[IdentityCredential]
  for i in 0 ..< n:
    credentials.add(generateCredentials())
  return credentials

proc getContractAddressFromDeployScriptOutput(output: string): Result[string, string] =
  const searchStr = "Return ==\n0: address "
  const addressLength = 42 # Length of an Ethereum address in hex format
  let idx = output.find(searchStr)
  if idx >= 0:
    let startPos = idx + searchStr.len
    let endPos = output.find('\n', startPos)
    if (endPos - startPos) >= addressLength:
      let address = output[startPos ..< endPos]
      return ok(address)
  return err("Unable to find contract address in deploy script output")

proc getForgePath(): string =
  var forgePath = ""
  if existsEnv("XDG_CONFIG_HOME"):
    forgePath = joinPath(forgePath, os.getEnv("XDG_CONFIG_HOME", ""))
  else:
    forgePath = joinPath(forgePath, os.getEnv("HOME", ""))
  forgePath = joinPath(forgePath, ".foundry/bin/forge")
  return $forgePath

template execForge(cmd: string): tuple[output: string, exitCode: int] =
  # unset env vars that affect e.g. "forge script" before running forge
  execCmdEx("unset ETH_FROM ETH_PASSWORD && " & cmd)

contract(ERC20Token):
  proc allowance(owner: Address, spender: Address): UInt256 {.view.}
  proc balanceOf(account: Address): UInt256 {.view.}

proc getTokenBalance(
    web3: Web3, tokenAddress: Address, account: Address
): Future[UInt256] {.async.} =
  let token = web3.contractSender(ERC20Token, tokenAddress)
  return await token.balanceOf(account).call()

proc ethToWei(eth: UInt256): UInt256 =
  eth * 1000000000000000000.u256

proc sendMintCall(
    web3: Web3,
    accountFrom: Address,
    tokenAddress: Address,
    recipientAddress: Address,
    amountTokens: UInt256,
    recipientBalanceBeforeExpectedTokens: Option[UInt256] = none(UInt256),
): Future[void] {.async.} =
  let doBalanceAssert = recipientBalanceBeforeExpectedTokens.isSome()

  if doBalanceAssert:
    let balanceBeforeMint = await getTokenBalance(web3, tokenAddress, recipientAddress)
    let balanceBeforeExpectedTokens = recipientBalanceBeforeExpectedTokens.get()
    assert balanceBeforeMint == balanceBeforeExpectedTokens,
      fmt"Balance is {balanceBeforeMint} before minting but expected {balanceBeforeExpectedTokens}"

  # OpenZeppelin ERC20 mint(address,uint256) selector.
  let mintSelector = "0x40c10f19"
  let addressHex = recipientAddress.toHex()
  let paddedAddress = addressHex.align(64, '0')

  let amountHex = amountTokens.toHex()
  let amountWithout0x =
    if amountHex.toLower().startsWith("0x"):
      amountHex[2 .. ^1]
    else:
      amountHex
  let paddedAmount = amountWithout0x.align(64, '0')
  let mintCallData = mintSelector & paddedAddress & paddedAmount
  let gasPrice = int(await web3.provider.eth_gasPrice())

  var tx: TransactionArgs
  tx.`from` = Opt.some(accountFrom)
  tx.to = Opt.some(tokenAddress)
  tx.value = Opt.some(0.u256)
  tx.gasPrice = Opt.some(Quantity(gasPrice))
  tx.data = Opt.some(byteutils.hexToSeqByte(mintCallData))

  trace "Sending mint call"
  discard await web3.send(tx)

  let balanceOfSelector = "0x70a08231"
  let balanceCallData = balanceOfSelector & paddedAddress

  await sleepAsync(500.milliseconds)

  if doBalanceAssert:
    let balanceAfterMint = await getTokenBalance(web3, tokenAddress, recipientAddress)
    let balanceAfterExpectedTokens =
      recipientBalanceBeforeExpectedTokens.get() + amountTokens
    assert balanceAfterMint == balanceAfterExpectedTokens,
      fmt"Balance is {balanceAfterMint} after transfer but expected {balanceAfterExpectedTokens}"

proc checkTokenAllowance(
    web3: Web3, tokenAddress: Address, owner: Address, spender: Address
): Future[UInt256] {.async.} =
  let token = web3.contractSender(ERC20Token, tokenAddress)
  let allowance = await token.allowance(owner, spender).call()
  trace "Current allowance", owner = owner, spender = spender, allowance = allowance
  return allowance

proc setupContractDeployment(
    forgePath: string, submodulePath: string
): Result[void, string] =
  trace "Contract deployer paths", forgePath = forgePath, submodulePath = submodulePath
  try:
    let (forgeCleanOutput, forgeCleanExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && {forgePath} clean""")
    if forgeCleanExitCode != 0:
      return err("forge clean command failed")

    let (forgeInstallOutput, forgeInstallExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && {forgePath} install""")
    if forgeInstallExitCode != 0:
      return err("forge install command failed")

    let (pnpmInstallOutput, pnpmInstallExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && pnpm install""")
    if pnpmInstallExitCode != 0:
      return err("pnpm install command failed" & pnpmInstallOutput)

    let (forgeBuildOutput, forgeBuildExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && {forgePath} build""")
    if forgeBuildExitCode != 0:
      return err("forge build command failed")

    # Forge requires these env vars to be set; values are unused on local testnet.
    putEnv("API_KEY_CARDONA", "123")
    putEnv("API_KEY_LINEASCAN", "123")
    putEnv("API_KEY_ETHERSCAN", "123")
  except OSError, IOError:
    return err("Command execution failed: " & getCurrentExceptionMsg())
  return ok()

proc deployTestToken*(
    pk: keys.PrivateKey, acc: Address, web3: Web3
): Future[Result[Address, string]] {.async.} =
  ## Deploys the ERC-20 test token used to pay the RLN membership registration fee.

  # Path is relative; RLN tests must be run from the project root.
  let submodulePath = absolutePath("./vendor/waku-rlnv2-contract")

  if not dirExists(submodulePath):
    error "Submodule path does not exist", submodulePath = submodulePath
    return err("Submodule path does not exist: " & submodulePath)

  let forgePath = getForgePath()

  setupContractDeployment(forgePath, submodulePath).isOkOr:
    error "Failed to setup contract deployment", error = $error
    return err("Failed to setup contract deployment: " & $error)

  let forgeCmdTestToken =
    fmt"""cd {submodulePath} && {forgePath} script test/TestToken.sol --broadcast -vvv --rpc-url http://localhost:8540 --tc TestTokenFactory --private-key {pk} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployTestToken, exitCodeDeployTestToken) = execForge(forgeCmdTestToken)
  if exitCodeDeployTestToken != 0:
    error "Forge command to deploy TestToken contract failed",
      error = outputDeployTestToken
    return
      err("Forge command to deploy TestToken contract failed: " & outputDeployTestToken)

  let testTokenAddress = getContractAddressFromDeployScriptOutput(outputDeployTestToken).valueOr:
    error "Failed to get TestToken contract address from deploy script output",
      error = $error
    return err(
      "Failed to get TestToken contract address from deploy script output: " & $error
    )
  debug "Address of the TestToken contract", testTokenAddress

  let testTokenAddressBytes = hexToByteArray[20](testTokenAddress)
  let testTokenAddressAddress = Address(testTokenAddressBytes)
  putEnv("TOKEN_ADDRESS", testTokenAddressAddress.toHex())

  return ok(testTokenAddressAddress)

proc approveTokenAllowanceAndVerify*(
    web3: Web3,
    accountFrom: Address,
    privateKey: keys.PrivateKey,
    tokenAddress: Address,
    spender: Address,
    amountWei: UInt256,
    expectedAllowanceBefore: Option[UInt256] = none(UInt256),
): Future[Result[TxHash, string]] {.async.} =
  var allowanceBefore: UInt256
  if expectedAllowanceBefore.isSome():
    allowanceBefore =
      await checkTokenAllowance(web3, tokenAddress, accountFrom, spender)
    let expected = expectedAllowanceBefore.get()
    if allowanceBefore != expected:
      return
        err(fmt"Allowance is {allowanceBefore} before approval but expected {expected}")

  # Swap in the holder's key so the approve tx is signed as the token owner;
  # restored in `finally`.
  let oldPrivateKey = web3.privateKey
  web3.privateKey = Opt.some(privateKey)
  web3.lastKnownNonce = Opt.none(Quantity)

  try:
    # ERC20 approve(address,uint256) selector.
    const APPROVE_SELECTOR = "0x095ea7b3"
    let addressHex = spender.toHex().align(64, '0')
    let amountHex = amountWei.toHex().align(64, '0')
    let approveCallData = APPROVE_SELECTOR & addressHex & amountHex

    let gasPrice = await web3.provider.eth_gasPrice()

    var tx: TransactionArgs
    tx.`from` = Opt.some(accountFrom)
    tx.to = Opt.some(tokenAddress)
    tx.value = Opt.some(0.u256)
    tx.gasPrice = Opt.some(gasPrice)
    tx.gas = Opt.some(Quantity(100000))
    tx.data = Opt.some(byteutils.hexToSeqByte(approveCallData))
    tx.chainId = Opt.some(CHAIN_ID)

    trace "Sending approve call", tx = tx
    let txHash = await web3.send(tx)
    let receipt = await web3.getMinedTransactionReceipt(txHash)

    if receipt.status.isNone():
      return err("Approval transaction failed receipt is none")
    if receipt.status.get() != 1.Quantity:
      return err("Approval transaction failed status quantity not 1")

    let allowanceAfter =
      await checkTokenAllowance(web3, tokenAddress, accountFrom, spender)
    let expectedAfter =
      if expectedAllowanceBefore.isSome():
        expectedAllowanceBefore.get() + amountWei
      else:
        amountWei

    if allowanceAfter < expectedAfter:
      return err(
        fmt"Allowance is {allowanceAfter} after approval but expected at least {expectedAfter}"
      )

    return ok(txHash)
  except CatchableError as e:
    return err(fmt"Failed to send approve transaction: {e.msg}")
  finally:
    web3.privateKey = oldPrivateKey

proc executeForgeContractDeployScripts*(
    privateKey: keys.PrivateKey, acc: Address, web3: Web3
): Future[Result[Address, string]] {.async, gcsafe.} =
  ## Deploys the RLN contracts via forge scripts; returns the proxy address.

  # Path is relative; RLN tests must be run from the project root.
  let submodulePath = "./vendor/waku-rlnv2-contract"

  if not dirExists(submodulePath):
    error "Submodule path does not exist", submodulePath = submodulePath
    return err("Submodule path does not exist: " & submodulePath)

  let forgePath = getForgePath()

  if not fileExists(forgePath):
    error "Forge executable not found", forgePath = forgePath
    return err("Forge executable not found: " & forgePath)

  let setupContractEnv = setupContractDeployment(forgePath, submodulePath)
  if setupContractEnv.isErr():
    error "Failed to setup contract deployment"
    return err("Failed to setup contract deployment")

  let forgeCmdPriceCalculator =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployPriceCalculator --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployPriceCalculator, exitCodeDeployPriceCalculator) =
    execForge(forgeCmdPriceCalculator)
  if exitCodeDeployPriceCalculator != 0:
    return error("Forge command to deploy LinearPriceCalculator contract failed")

  let priceCalculatorAddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployPriceCalculator)
  if priceCalculatorAddressRes.isErr():
    error "Failed to get LinearPriceCalculator contract address from deploy script output"
  let priceCalculatorAddress = priceCalculatorAddressRes.get()
  putEnv("PRICE_CALCULATOR_ADDRESS", priceCalculatorAddress)

  let forgeCmdWakuRln =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployWakuRlnV2 --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployWakuRln, exitCodeDeployWakuRln) = execForge(forgeCmdWakuRln)
  if exitCodeDeployWakuRln != 0:
    error "Forge command to deploy WakuRlnV2 contract failed",
      output = outputDeployWakuRln
    return err("Forge command to deploy WakuRlnV2 contract failed")

  let wakuRlnV2AddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployWakuRln)
  if wakuRlnV2AddressRes.isErr():
    error "Failed to get WakuRlnV2 contract address from deploy script output"
    return err("Failed to get WakuRlnV2 contract address from deploy script output")
  let wakuRlnV2Address = wakuRlnV2AddressRes.get()
  putEnv("WAKURLNV2_ADDRESS", wakuRlnV2Address)

  let forgeCmdProxy =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployProxy --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployProxy, exitCodeDeployProxy) = execForge(forgeCmdProxy)
  if exitCodeDeployProxy != 0:
    error "Forge command to deploy Proxy failed", error = outputDeployProxy
    return err("Forge command to deploy Proxy failed")

  let proxyAddress = getContractAddressFromDeployScriptOutput(outputDeployProxy)
  let proxyAddressBytes = hexToByteArray[20](proxyAddress.get())
  let proxyAddressAddress = Address(proxyAddressBytes)

  debug "Address of the Proxy contract", proxyAddressAddress

  await web3.close()
  return ok(proxyAddressAddress)

proc sendEthTransfer*(
    web3: Web3,
    accountFrom: Address,
    accountTo: Address,
    amountWei: UInt256,
    accountToBalanceBeforeExpectedWei: Option[UInt256] = none(UInt256),
): Future[TxHash] {.async.} =
  let doBalanceAssert = accountToBalanceBeforeExpectedWei.isSome()

  if doBalanceAssert:
    let balanceBeforeWei = await web3.provider.eth_getBalance(accountTo, "latest")
    let balanceBeforeExpectedWei = accountToBalanceBeforeExpectedWei.get()
    assert balanceBeforeWei == balanceBeforeExpectedWei,
      fmt"Balance is {balanceBeforeWei} before transfer but expected {balanceBeforeExpectedWei}"

  let gasPrice = int(await web3.provider.eth_gasPrice())

  var tx: TransactionArgs
  tx.`from` = Opt.some(accountFrom)
  tx.to = Opt.some(accountTo)
  tx.value = Opt.some(amountWei)
  tx.gasPrice = Opt.some(Quantity(gasPrice))

  # TODO: handle the error if sending fails
  let txHash = await web3.send(tx)

  await sleepAsync(200.milliseconds)

  if doBalanceAssert:
    let balanceAfterWei = await web3.provider.eth_getBalance(accountTo, "latest")
    let balanceAfterExpectedWei = accountToBalanceBeforeExpectedWei.get() + amountWei
    assert balanceAfterWei == balanceAfterExpectedWei,
      fmt"Balance is {balanceAfterWei} after transfer but expected {balanceAfterExpectedWei}"

  return txHash

proc createEthAccount*(
    ethAmount: UInt256 = 1000.u256
): Future[(keys.PrivateKey, Address)] {.async.} =
  let web3 = await newWeb3(EthClient)
  let accounts = await web3.provider.eth_accounts()
  let gasPrice = Quantity(await web3.provider.eth_gasPrice())
  web3.defaultAccount = accounts[0]

  let pk = keys.PrivateKey.random(keys.newRng()[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  var tx: TransactionArgs
  tx.`from` = Opt.some(accounts[0])
  tx.value = Opt.some(ethToWei(ethAmount))
  tx.to = Opt.some(acc)
  tx.gasPrice = Opt.some(Quantity(gasPrice))

  discard await web3.send(tx)
  let balance = await web3.provider.eth_getBalance(acc, "latest")
  assert balance == ethToWei(ethAmount),
    fmt"Balance is {balance} but expected {ethToWei(ethAmount)}"

  return (pk, acc)

proc createEthAccount*(web3: Web3): (keys.PrivateKey, Address) =
  let pk = keys.PrivateKey.random(keys.newRng()[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  return (pk, acc)

proc getAnvilPath*(): string =
  var anvilPath = ""
  if existsEnv("XDG_CONFIG_HOME"):
    anvilPath = joinPath(anvilPath, os.getEnv("XDG_CONFIG_HOME", ""))
  else:
    anvilPath = joinPath(anvilPath, os.getEnv("HOME", ""))
  anvilPath = joinPath(anvilPath, ".foundry/bin/anvil")
  return $anvilPath

proc decompressGzipFile*(
    compressedPath: string, targetPath: string
): Result[void, string] =
  ## Decompress a gzipped file using the gunzip command-line utility
  let cmd = fmt"gunzip -c {compressedPath} > {targetPath}"

  try:
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      return err(
        "Failed to decompress '" & compressedPath & "' to '" & targetPath & "': " &
          output
      )
  except OSError as e:
    return err("Failed to execute gunzip command: " & e.msg)
  except IOError as e:
    return err("Failed to execute gunzip command: " & e.msg)

  ok()

proc compressGzipFile*(sourcePath: string, targetPath: string): Result[void, string] =
  ## Compress a file with gzip using the gzip command-line utility
  let cmd = fmt"gzip -c {sourcePath} > {targetPath}"

  try:
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      return err(
        "Failed to compress '" & sourcePath & "' to '" & targetPath & "': " & output
      )
  except OSError as e:
    return err("Failed to execute gzip command: " & e.msg)
  except IOError as e:
    return err("Failed to execute gzip command: " & e.msg)

  ok()

proc runAnvil*(
    port: int = 8540,
    chainId: string = "1234",
    stateFile: Option[string] = none(string),
    dumpStateOnExit: bool = false,
): Process =
  # Gas/fee values mirror Linea Sepolia testnet.
  # See https://book.getfoundry.sh/reference/anvil/ for option details.
  try:
    let anvilPath = getAnvilPath()
    debug "Anvil path", anvilPath

    var args = @[
      "--port",
      $port,
      "--gas-limit",
      "30000000",
      "--gas-price",
      "7",
      "--base-fee",
      "7",
      "--balance",
      "10000000000",
      "--chain-id",
      $chainId,
      "--disable-min-priority-fee",
      "--silent",
    ]

    if stateFile.isSome():
      var statePath = stateFile.get()
      debug "State file parameter provided",
        statePath = statePath,
        dumpStateOnExit = dumpStateOnExit,
        absolutePath = absolutePath(statePath)

      if statePath.endsWith(".gz"):
        let decompressedPath = statePath[0 .. ^4]

        if not fileExists(decompressedPath):
          decompressGzipFile(statePath, decompressedPath).isOkOr:
            error "Failed to decompress state file", error = error
            return nil

        statePath = decompressedPath

      if dumpStateOnExit:
        let stateDir = parentDir(statePath)
        if not dirExists(stateDir):
          createDir(stateDir)
        # Fresh deployment: start clean and dump state on exit.
        args.add("--dump-state")
        args.add(statePath)
        debug "Anvil configured to dump state on exit", path = statePath
      else:
        # Load-only so we don't clobber the committed cached state file.
        if fileExists(statePath):
          args.add("--load-state")
          args.add(statePath)
          debug "Anvil configured to load state file (read-only)", path = statePath
        else:
          warn "State file does not exist, anvil will start fresh",
            path = statePath, absolutePath = absolutePath(statePath)
    else:
      debug "No state file provided, anvil will start fresh without state persistence"

    debug "Starting anvil with arguments", args = args.join(" ")

    let runAnvil =
      startProcess(anvilPath, args = args, options = {poUsePath, poStdErrToStdOut})
    let anvilPID = runAnvil.processID

    # Poll the JSON-RPC port to detect Anvil process readiness.
    const startupTimeoutMs = 10_000
    const pollIntervalMs = 100
    var elapsed = 0
    var ready = false
    while elapsed < startupTimeoutMs:
      if not runAnvil.running:
        error "Anvil daemon exited before becoming ready", pid = anvilPID
        return
      try:
        let sock = newSocket()
        try:
          sock.connect("127.0.0.1", Port(port), timeout = 500)
          ready = true
        finally:
          close(sock)
        if ready:
          break
      except CatchableError:
        discard
      sleep(pollIntervalMs)
      elapsed += pollIntervalMs

    if not ready:
      error "Anvil daemon did not become ready within timeout",
        pid = anvilPID, timeoutMs = startupTimeoutMs
      return

    debug "Anvil daemon is running and ready", pid = anvilPID
    return runAnvil
  except: # TODO: Fix "BareExcept" warning
    error "Anvil daemon run failed", err = getCurrentExceptionMsg()

proc stopAnvil*(runAnvil: Process) {.used.} =
  if runAnvil.isNil:
    error "stopAnvil called with nil Process"
    return

  let anvilPID = runAnvil.processID
  debug "Stopping Anvil daemon", anvilPID = anvilPID

  try:
    when not defined(windows):
      discard execCmdEx(fmt"kill -TERM {anvilPID}")
      # Give Anvil time to dump state on graceful shutdown before escalating to KILL.
      sleep(200)
      let checkResult = execCmdEx(fmt"kill -0 {anvilPID} 2>/dev/null")
      if checkResult.exitCode == 0:
        warn "Anvil process still running after TERM signal, sending KILL",
          anvilPID = anvilPID
        discard execCmdEx(fmt"kill -9 {anvilPID}")
    else:
      discard execCmdEx(fmt"taskkill /F /PID {anvilPID}")

    close(runAnvil)
    debug "Anvil daemon stopped", anvilPID = anvilPID
  except Exception as e:
    error "Error stopping Anvil daemon", anvilPID = anvilPID, error = e.msg

proc setupOnchainGroupManager*(
    ethClientUrl: string = EthClient,
    amountEth: UInt256 = 10.u256,
    deployContracts: bool = true,
): Future[OnchainGroupManager] {.async.} =
  ## Setup an onchain group manager for testing
  ## If deployContracts is false, it will assume that the Anvil testnet already has the required contracts deployed, this significantly speeds up test runs.
  ## To run Anvil with a cached state file containing pre-deployed contracts, see runAnvil documentation.
  ## 
  ## To generate/update the cached state file:
  ## 1. Call runAnvil with stateFile and dumpStateOnExit=true
  ## 2. Run setupOnchainGroupManager with deployContracts=true to deploy contracts
  ## 3. The state will be saved to the specified file when anvil exits
  ## 4. Commit this file to git
  ## 
  ## To use cached state:
  ## 1. Call runAnvil with stateFile and dumpStateOnExit=false
  ## 2. Anvil loads state in read-only mode (won't overwrite the cached file)
  ## 3. Call setupOnchainGroupManager with deployContracts=false
  ## 4. Tests run fast using pre-deployed contracts
  let rlnInstanceRes = createRlnInstance()
  check:
    rlnInstanceRes.isOk()

  let rlnInstance = rlnInstanceRes.get()

  var web3 = await newWeb3(ethClientUrl)
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]

  var privateKey: keys.PrivateKey
  var acc: Address
  var testTokenAddress: Address
  var contractAddress: Address

  if not deployContracts:
    debug "Using contract addresses from constants"

    testTokenAddress = Address(hexToByteArray[20](TOKEN_ADDRESS))
    contractAddress = Address(hexToByteArray[20](WAKU_RLNV2_PROXY_ADDRESS))

    (privateKey, acc) = createEthAccount(web3)

    discard await sendEthTransfer(web3, web3.defaultAccount, acc, ethToWei(1000.u256))

    await sendMintCall(
      web3, web3.defaultAccount, testTokenAddress, acc, ethToWei(1000.u256)
    )

    let tokenApprovalResult = await approveTokenAllowanceAndVerify(
      web3, acc, privateKey, testTokenAddress, contractAddress, ethToWei(2000.u256)
    )
    assert tokenApprovalResult.isOk(), tokenApprovalResult.error
  else:
    debug "Performing Token and RLN contracts deployment"
    (privateKey, acc) = createEthAccount(web3)

    discard await sendEthTransfer(
      web3, web3.defaultAccount, acc, ethToWei(1000.u256), some(0.u256)
    )

    testTokenAddress = (await deployTestToken(privateKey, acc, web3)).valueOr:
      assert false, "Failed to deploy test token contract: " & $error
      return

    await sendMintCall(
      web3,
      web3.defaultAccount,
      testTokenAddress,
      acc,
      ethToWei(1000.u256),
      some(0.u256),
    )

    contractAddress = (await executeForgeContractDeployScripts(privateKey, acc, web3)).valueOr:
      assert false, "Failed to deploy RLN contract: " & $error
      return

    # `executeForgeContractDeployScripts` shells out to `forge` via blocking
    # `execCmdEx` calls (many seconds). While those run the chronos event loop
    # is frozen and the existing web3 HTTP connection to Anvil rots; the next
    # eth_call fails with "Not connected". Reconnect before continuing.
    try:
      await web3.close()
    except CatchableError:
      discard
    web3 = await newWeb3(ethClientUrl)
    web3.defaultAccount = accounts[1]

    let tokenApprovalResult = await approveTokenAllowanceAndVerify(
      web3,
      acc,
      privateKey,
      testTokenAddress,
      contractAddress,
      ethToWei(2000.u256),
      some(0.u256),
    )

    assert tokenApprovalResult.isOk(), tokenApprovalResult.error

  let manager = OnchainGroupManager(
    ethClientUrls: @[ethClientUrl],
    ethContractAddress: $contractAddress,
    chainId: CHAIN_ID,
    ethPrivateKey: some($privateKey),
    rlnInstance: rlnInstance,
    onFatalErrorAction: proc(errStr: string) =
      raiseAssert errStr
    ,
  )

  return manager

{.pop.}
