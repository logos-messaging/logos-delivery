{.used.}

{.push raises: [].}

import
  std/[options, os, osproc, streams, strutils, strformat],
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
  waku/[
    waku_rln_relay,
    waku_rln_relay/protocol_types,
    waku_rln_relay/constants,
    waku_rln_relay/rln,
  ],
  ../testlib/common

const CHAIN_ID* = 1234'u256

# Path to the file which Anvil loads at startup to initialize the chain with pre-deployed contracts, an account funded with tokens and approved for spending
const DEFAULT_ANVIL_STATE_PATH* =
  "tests/waku_rln_relay/anvil_state/state-deployed-contracts-mint-and-approved.json.gz"
# The contract address of the TestStableToken used for the RLN Membership registration fee
const TOKEN_ADDRESS* = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
# The contract address used ti interact with the WakuRLNV2 contract via the proxy
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

  # Create mint transaction
  # Method ID for mint(address,uint256) is 0x40c10f19 which is part of the openzeppelin ERC20 standard
  # The method ID for a deployed test token can be viewed here https://sepolia.lineascan.build/address/0x185A0015aC462a0aECb81beCc0497b649a64B9ea#writeContract
  let mintSelector = "0x40c10f19"
  let addressHex = recipientAddress.toHex()
  # Pad the address and amount to 32 bytes each
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

  # Create the transaction
  var tx: TransactionArgs
  tx.`from` = Opt.some(accountFrom)
  tx.to = Opt.some(tokenAddress)
  tx.value = Opt.some(0.u256) # No ETH is sent for token operations
  tx.gasPrice = Opt.some(Quantity(gasPrice))
  tx.data = Opt.some(byteutils.hexToSeqByte(mintCallData))

  trace "Sending mint call"
  discard await web3.send(tx)

  let balanceOfSelector = "0x70a08231"
  let balanceCallData = balanceOfSelector & paddedAddress

  # Wait a bit for transaction to be mined
  await sleepAsync(500.milliseconds)

  if doBalanceAssert:
    let balanceAfterMint = await getTokenBalance(web3, tokenAddress, recipientAddress)
    let balanceAfterExpectedTokens =
      recipientBalanceBeforeExpectedTokens.get() + amountTokens
    assert balanceAfterMint == balanceAfterExpectedTokens,
      fmt"Balance is {balanceAfterMint} after transfer but expected {balanceAfterExpectedTokens}"

# Check how many tokens a spender (the RLN contract) is allowed to spend on behalf of the owner (account which wishes to register a membership)
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
  # Build the Foundry project
  try:
    let (forgeCleanOutput, forgeCleanExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && {forgePath} clean""")
    trace "Executed forge clean command", output = forgeCleanOutput
    if forgeCleanExitCode != 0:
      return err("forge clean command failed")

    let (forgeInstallOutput, forgeInstallExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && {forgePath} install""")
    trace "Executed forge install command", output = forgeInstallOutput
    if forgeInstallExitCode != 0:
      return err("forge install command failed")

    let (pnpmInstallOutput, pnpmInstallExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && pnpm install""")
    trace "Executed pnpm install command", output = pnpmInstallOutput
    if pnpmInstallExitCode != 0:
      return err("pnpm install command failed" & pnpmInstallOutput)

    let (forgeBuildOutput, forgeBuildExitCode) =
      execCmdEx(fmt"""cd {submodulePath} && {forgePath} build""")
    trace "Executed forge build command", output = forgeBuildOutput
    if forgeBuildExitCode != 0:
      return err("forge build command failed")

    # Set the environment variable API keys to anything for local testnet deployment
    putEnv("API_KEY_CARDONA", "123")
    putEnv("API_KEY_LINEASCAN", "123")
    putEnv("API_KEY_ETHERSCAN", "123")
  except OSError, IOError:
    return err("Command execution failed: " & getCurrentExceptionMsg())
  return ok()

proc deployTestToken*(
    pk: keys.PrivateKey, acc: Address, web3: Web3
): Future[Result[Address, string]] {.async.} =
  ## Executes a Foundry forge script that deploys the a token contract (ERC-20) used for testing. This is a prerequisite to enable the contract deployment and this token contract address needs to be minted and approved for the accounts that need to register memberships with the contract
  ## submodulePath: path to the submodule containing contract deploy scripts

  # All RLN related tests should be run from the root directory of the project
  let submodulePath = absolutePath("./vendor/waku-rlnv2-contract")

  # Verify submodule path exists
  if not dirExists(submodulePath):
    error "Submodule path does not exist", submodulePath = submodulePath
    return err("Submodule path does not exist: " & submodulePath)

  let forgePath = getForgePath()

  setupContractDeployment(forgePath, submodulePath).isOkOr:
    error "Failed to setup contract deployment", error = $error
    return err("Failed to setup contract deployment: " & $error)

  # Deploy TestToken contract
  let forgeCmdTestToken =
    fmt"""cd {submodulePath} && {forgePath} script test/TestToken.sol --broadcast -vvv --rpc-url http://localhost:8540 --tc TestTokenFactory --private-key {pk} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployTestToken, exitCodeDeployTestToken) = execForge(forgeCmdTestToken)
  trace "Executed forge command to deploy TestToken contract",
    output = outputDeployTestToken
  if exitCodeDeployTestToken != 0:
    error "Forge command to deploy TestToken contract failed",
      error = outputDeployTestToken
    return
      err("Forge command to deploy TestToken contract failed: " & outputDeployTestToken)

  # Parse the command output to find contract address
  let testTokenAddress = getContractAddressFromDeployScriptOutput(outputDeployTestToken).valueOr:
    error "Failed to get TestToken contract address from deploy script output",
      error = $error
    return err(
      "Failed to get TestToken contract address from deploy script output: " & $error
    )
  info "Address of the TestToken contract", testTokenAddress

  let testTokenAddressBytes = hexToByteArray[20](testTokenAddress)
  let testTokenAddressAddress = Address(testTokenAddressBytes)
  putEnv("TOKEN_ADDRESS", testTokenAddressAddress.toHex())

  return ok(testTokenAddressAddress)

# Sends an ERC20 token approval call to allow a spender to spend a certain amount of tokens on behalf of the owner
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

  # Temporarily set the private key
  let oldPrivateKey = web3.privateKey
  web3.privateKey = Opt.some(privateKey)
  web3.lastKnownNonce = Opt.none(Quantity)

  try:
    # ERC20 approve function signature: approve(address spender, uint256 amount)
    # Method ID for approve(address,uint256) is 0x095ea7b3
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

    # Single verification check after mining (no extra sleep needed)
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
    # Restore the old private key
    web3.privateKey = oldPrivateKey

proc executeForgeContractDeployScripts*(
    privateKey: keys.PrivateKey, acc: Address, web3: Web3
): Future[Result[Address, string]] {.async, gcsafe.} =
  ## Executes a set of foundry forge scripts required to deploy the RLN contract and returns the deployed proxy contract address
  ## submodulePath: path to the submodule containing contract deploy scripts

  # All RLN related tests should be run from the root directory of the project
  let submodulePath = "./vendor/waku-rlnv2-contract"

  # Verify submodule path exists
  if not dirExists(submodulePath):
    error "Submodule path does not exist", submodulePath = submodulePath
    return err("Submodule path does not exist: " & submodulePath)

  let forgePath = getForgePath()
  info "Forge path", forgePath

  # Verify forge executable exists
  if not fileExists(forgePath):
    error "Forge executable not found", forgePath = forgePath
    return err("Forge executable not found: " & forgePath)

  trace "contract deployer account details", account = acc, privateKey = privateKey
  let setupContractEnv = setupContractDeployment(forgePath, submodulePath)
  if setupContractEnv.isErr():
    error "Failed to setup contract deployment"
    return err("Failed to setup contract deployment")

  # Deploy LinearPriceCalculator contract
  let forgeCmdPriceCalculator =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployPriceCalculator --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployPriceCalculator, exitCodeDeployPriceCalculator) =
    execForge(forgeCmdPriceCalculator)
  trace "Executed forge command to deploy LinearPriceCalculator contract",
    output = outputDeployPriceCalculator
  if exitCodeDeployPriceCalculator != 0:
    return error("Forge command to deploy LinearPriceCalculator contract failed")

  # Parse the output to find contract address
  let priceCalculatorAddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployPriceCalculator)
  if priceCalculatorAddressRes.isErr():
    error "Failed to get LinearPriceCalculator contract address from deploy script output"
  let priceCalculatorAddress = priceCalculatorAddressRes.get()
  info "Address of the LinearPriceCalculator contract", priceCalculatorAddress
  putEnv("PRICE_CALCULATOR_ADDRESS", priceCalculatorAddress)

  let forgeCmdWakuRln =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployWakuRlnV2 --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployWakuRln, exitCodeDeployWakuRln) = execForge(forgeCmdWakuRln)
  trace "Executed forge command to deploy WakuRlnV2 contract",
    output = outputDeployWakuRln
  if exitCodeDeployWakuRln != 0:
    error "Forge command to deploy WakuRlnV2 contract failed",
      output = outputDeployWakuRln

  # Parse the output to find contract address
  let wakuRlnV2AddressRes =
    getContractAddressFromDeployScriptOutput(outputDeployWakuRln)
  if wakuRlnV2AddressRes.isErr():
    error "Failed to get WakuRlnV2 contract address from deploy script output"
    ##TODO: raise exception here?
  let wakuRlnV2Address = wakuRlnV2AddressRes.get()
  info "Address of the WakuRlnV2 contract", wakuRlnV2Address
  putEnv("WAKURLNV2_ADDRESS", wakuRlnV2Address)

  # Deploy Proxy contract
  let forgeCmdProxy =
    fmt"""cd {submodulePath} && {forgePath} script script/Deploy.s.sol --broadcast -vvvv --rpc-url http://localhost:8540 --tc DeployProxy --private-key {privateKey} && rm -rf broadcast/*/*/run-1*.json && rm -rf cache/*/*/run-1*.json"""
  let (outputDeployProxy, exitCodeDeployProxy) = execForge(forgeCmdProxy)
  trace "Executed forge command to deploy proxy contract", output = outputDeployProxy
  if exitCodeDeployProxy != 0:
    error "Forge command to deploy Proxy failed", error = outputDeployProxy
    return err("Forge command to deploy Proxy failed")

  let proxyAddress = getContractAddressFromDeployScriptOutput(outputDeployProxy)
  let proxyAddressBytes = hexToByteArray[20](proxyAddress.get())
  let proxyAddressAddress = Address(proxyAddressBytes)

  info "Address of the Proxy contract", proxyAddressAddress

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

  # Wait a bit for transaction to be mined
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

  let pk = keys.PrivateKey.random(rng[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  var tx: TransactionArgs
  tx.`from` = Opt.some(accounts[0])
  tx.value = Opt.some(ethToWei(ethAmount))
  tx.to = Opt.some(acc)
  tx.gasPrice = Opt.some(Quantity(gasPrice))

  # Send ethAmount to acc
  discard await web3.send(tx)
  let balance = await web3.provider.eth_getBalance(acc, "latest")
  assert balance == ethToWei(ethAmount),
    fmt"Balance is {balance} but expected {ethToWei(ethAmount)}"

  return (pk, acc)

proc createEthAccount*(web3: Web3): (keys.PrivateKey, Address) =
  let pk = keys.PrivateKey.random(rng[])
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

# Runs Anvil daemon
proc runAnvil*(
    port: int = 8540,
    chainId: string = "1234",
    stateFile: Option[string] = none(string),
    dumpStateOnExit: bool = false,
): Process =
  # Passed options are
  # --port                            Port to listen on.
  # --gas-limit                       Sets the block gas limit in WEI.
  # --balance                         The default account balance, specified in ether.
  # --chain-id                        Chain ID of the network.
  # --load-state                      Initialize the chain from a previously saved state snapshot (read-only)
  # --dump-state                      Dump the state on exit to the given file (write-only)
  # Values used are representative of Linea Sepolia testnet
  # See anvil documentation https://book.getfoundry.sh/reference/anvil/ for more details
  try:
    let anvilPath = getAnvilPath()
    info "Anvil path", anvilPath

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
    ]

    # Add state file argument if provided
    if stateFile.isSome():
      var statePath = stateFile.get()
      info "State file parameter provided",
        statePath = statePath,
        dumpStateOnExit = dumpStateOnExit,
        absolutePath = absolutePath(statePath)

      # Check if the file is gzip compressed and handle decompression
      if statePath.endsWith(".gz"):
        let decompressedPath = statePath[0 .. ^4] # Remove .gz extension
        debug "Gzip compressed state file detected",
          compressedPath = statePath, decompressedPath = decompressedPath

        if not fileExists(decompressedPath):
          decompressGzipFile(statePath, decompressedPath).isOkOr:
            error "Failed to decompress state file", error = error
            return nil

        statePath = decompressedPath

      if dumpStateOnExit:
        # Ensure the directory exists
        let stateDir = parentDir(statePath)
        if not dirExists(stateDir):
          createDir(stateDir)
        # Fresh deployment: start clean and dump state on exit
        args.add("--dump-state")
        args.add(statePath)
        debug "Anvil configured to dump state on exit", path = statePath
      else:
        # Using cache: only load state, don't overwrite it (preserves clean cached state)
        if fileExists(statePath):
          args.add("--load-state")
          args.add(statePath)
          debug "Anvil configured to load state file (read-only)", path = statePath
        else:
          warn "State file does not exist, anvil will start fresh",
            path = statePath, absolutePath = absolutePath(statePath)
    else:
      info "No state file provided, anvil will start fresh without state persistence"

    info "Starting anvil with arguments", args = args.join(" ")

    let runAnvil =
      startProcess(anvilPath, args = args, options = {poUsePath, poStdErrToStdOut})
    let anvilPID = runAnvil.processID

    # We read stdout from Anvil to see when daemon is ready
    var anvilStartLog: string
    var cmdline: string
    while true:
      try:
        if runAnvil.outputstream.readLine(cmdline):
          anvilStartLog.add(cmdline)
          if cmdline.contains("Listening on 127.0.0.1:" & $port):
            break
        else:
          error "Anvil daemon exited (closed output)",
            pid = anvilPID, startLog = anvilStartLog
          return
      except Exception, CatchableError:
        warn "Anvil daemon stdout reading error; assuming it started OK",
          pid = anvilPID, startLog = anvilStartLog, err = getCurrentExceptionMsg()
        break
    info "Anvil daemon is running and ready", pid = anvilPID, startLog = anvilStartLog
    return runAnvil
  except: # TODO: Fix "BareExcept" warning
    error "Anvil daemon run failed", err = getCurrentExceptionMsg()

# Stops Anvil daemon
proc stopAnvil*(runAnvil: Process) {.used.} =
  if runAnvil.isNil:
    info "stopAnvil called with nil Process"
    return

  let anvilPID = runAnvil.processID
  info "Stopping Anvil daemon", anvilPID = anvilPID

  try:
    # Send termination signals
    when not defined(windows):
      discard execCmdEx(fmt"kill -TERM {anvilPID}")
      # Wait for graceful shutdown to allow state dumping
      sleep(200)
      # Only force kill if process is still running
      let checkResult = execCmdEx(fmt"kill -0 {anvilPID} 2>/dev/null")
      if checkResult.exitCode == 0:
        info "Anvil process still running after TERM signal, sending KILL",
          anvilPID = anvilPID
        discard execCmdEx(fmt"kill -9 {anvilPID}")
    else:
      discard execCmdEx(fmt"taskkill /F /PID {anvilPID}")

    # Close Process object to release resources
    close(runAnvil)
    info "Anvil daemon stopped", anvilPID = anvilPID
  except Exception as e:
    info "Error stopping Anvil daemon", anvilPID = anvilPID, error = e.msg

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

  let web3 = await newWeb3(ethClientUrl)
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]

  var privateKey: keys.PrivateKey
  var acc: Address
  var testTokenAddress: Address
  var contractAddress: Address

  if not deployContracts:
    info "Using contract addresses from constants"

    testTokenAddress = Address(hexToByteArray[20](TOKEN_ADDRESS))
    contractAddress = Address(hexToByteArray[20](WAKU_RLNV2_PROXY_ADDRESS))

    (privateKey, acc) = createEthAccount(web3)

    # Fund the test account
    discard await sendEthTransfer(web3, web3.defaultAccount, acc, ethToWei(1000.u256))

    # Mint tokens to the test account
    await sendMintCall(
      web3, web3.defaultAccount, testTokenAddress, acc, ethToWei(1000.u256)
    )

    # Approve the contract to spend tokens
    let tokenApprovalResult = await approveTokenAllowanceAndVerify(
      web3, acc, privateKey, testTokenAddress, contractAddress, ethToWei(200.u256)
    )
    assert tokenApprovalResult.isOk(), tokenApprovalResult.error
  else:
    info "Performing Token and RLN contracts deployment"
    (privateKey, acc) = createEthAccount(web3)

    # fund the default account
    discard await sendEthTransfer(
      web3, web3.defaultAccount, acc, ethToWei(1000.u256), some(0.u256)
    )

    testTokenAddress = (await deployTestToken(privateKey, acc, web3)).valueOr:
      assert false, "Failed to deploy test token contract: " & $error
      return

    # mint the token from the generated account
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

    # If the generated account wishes to register a membership, it needs to approve the contract to spend its tokens
    let tokenApprovalResult = await approveTokenAllowanceAndVerify(
      web3,
      acc,
      privateKey,
      testTokenAddress,
      contractAddress,
      ethToWei(200.u256),
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
