import
  web3,
  web3/eth_api_types,
  web3/primitives,
  eth/keys as keys,
  chronicles,
  nimcrypto/keccak as keccak,
  stint,
  json,
  std/strutils,
  stew/byteutils,
  sequtils

import
  ../../../waku_keystore,
  ../../conversion_utils,
  ../../protocol_types,
  ../group_manager_base

logScope:
  topics = "waku rln_relay onchain rpc_wrapper"

# using the when predicate does not work within the contract macro, hence need to dupe
contract(WakuRlnContract):
  # this serves as an entrypoint into the rln membership set
  proc register(
    idCommitment: UInt256, userMessageLimit: UInt32, idCommitmentsToErase: seq[UInt256]
  )

  # this event is emitted when a new member is registered
  proc MembershipRegistered(
    idCommitment: UInt256, membershipRateLimit: UInt256, index: UInt32
  ) {.event.}

  # Initializes the implementation contract (only used in unit tests)
  proc initialize(maxMessageLimit: UInt256)
  # this function denotes existence of a given user
  proc isInMembershipSet(idCommitment: Uint256): bool {.view.}
  # this constant describes the next index of a new member
  proc nextFreeIndex(): UInt256 {.view.}
  # this constant describes the block number this contract was deployed on
  proc deployedBlockNumber(): UInt256 {.view.}
  # this constant describes max message limit of rln contract
  proc maxMembershipRateLimit(): UInt256 {.view.}
  # this function returns the merkleProof for a given index
  proc getMerkleProof(index: UInt256): seq[byte] {.view.}
  # this function returns the Merkle root
  proc root(): Uint256 {.view.}

proc sendEthCallWithoutParams*(
    ethRpc: Web3,
    functionSignature: string,
    fromAddress: Address,
    toAddress: Address,
    chainId: UInt256,
): Future[Result[UInt256, string]] {.async.} =
  ## Workaround for web3 chainId=null issue on some networks (e.g., linea-sepolia)
  ## Makes contract calls with explicit chainId for view functions with no parameters
  let functionHash =
    keccak256.digest(functionSignature.toOpenArrayByte(0, functionSignature.len - 1))
  let functionSelector = functionHash.data[0 .. 3]
  let dataSignature = "0x" & functionSelector.mapIt(it.toHex(2)).join("")

  var tx: TransactionArgs
  tx.`from` = Opt.some(fromAddress)
  tx.to = Opt.some(toAddress)
  tx.value = Opt.some(0.u256)
  tx.data = Opt.some(byteutils.hexToSeqByte(dataSignature))
  tx.chainId = Opt.some(chainId)

  let resultBytes = await ethRpc.provider.eth_call(tx, "latest")
  if resultBytes.len == 0:
    return err("No result returned for function call: " & functionSignature)
  return ok(UInt256.fromBytesBE(resultBytes))

proc sendEthCallWithParams*(
    ethRpc: Web3,
    functionSignature: string,
    fromAddress: Address,
    toAddress: Address,
    chainId: UInt256,
    params: seq[byte] = @[],
): Future[Result[seq[byte], string]] {.async.} =
  ## Workaround for web3 chainId=null issue with parameterized contract calls
  let functionHash =
    keccak256.digest(functionSignature.toOpenArrayByte(0, functionSignature.len - 1))
  let functionSelector = functionHash.data[0 .. 3]
  let callData = functionSelector & params

  var tx: TransactionArgs
  tx.`from` = Opt.some(fromAddress)
  tx.to = Opt.some(toAddress)
  tx.value = Opt.some(0.u256)
  tx.data = Opt.some(callData)
  tx.chainId = Opt.some(chainId)

  let resultBytes = await ethRpc.provider.eth_call(tx, "latest")
  return ok(resultBytes)
