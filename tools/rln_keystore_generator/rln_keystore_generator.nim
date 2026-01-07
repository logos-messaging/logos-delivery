when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronicles, results, std/[tempfiles, sequtils]

import
  waku/[
    waku_keystore,
    waku_rln_relay/rln,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain,
  ]

logScope:
  topics = "rln_keystore_generator"

type RlnKeystoreGeneratorConf* = object
  execute*: bool
  ethContractAddress*: string
  ethClientUrls*: seq[string]
  chainId*: UInt256
  credPath*: string
  credPassword*: string
  userMessageLimit*: uint64
  ethPrivateKey*: string

proc doRlnKeystoreGenerator*(conf: RlnKeystoreGeneratorConf) =
  # 1. load configuration
  trace "configuration", conf = $conf

  # 2. generate credentials
  let credential = membershipKeyGen().valueOr:
    error "failure while generating credentials", error = error
    quit(QuitFailure)

  info "credentials",
    idTrapdoor = credential.idTrapdoor.inHex(),
    idNullifier = credential.idNullifier.inHex(),
    idSecretHash = credential.idSecretHash.inHex(),
    idCommitment = credential.idCommitment.inHex()

  if not conf.execute:
    info "not executing, exiting"
    quit(QuitSuccess)

  var onFatalErrorAction = proc(msg: string) {.gcsafe, closure.} =
    ## Action to be taken when an internal error occurs during the node run.
    ## e.g. the connection with the database is lost and not recovered.
    error "Unrecoverable error occurred", error = msg
    quit(QuitFailure)

  # 3. initialize OnchainGroupManager
  let groupManager = OnchainGroupManager(
    ethClientUrls: conf.ethClientUrls,
    chainId: conf.chainId,
    ethContractAddress: conf.ethContractAddress,
    keystorePath: none(string),
    keystorePassword: none(string),
    ethPrivateKey: some(conf.ethPrivateKey),
    onFatalErrorAction: onFatalErrorAction,
  )
  try:
    (waitFor groupManager.init()).isOkOr:
      error "failure while initializing OnchainGroupManager", error = $error
      quit(QuitFailure)
  # handling the exception is required since waitFor raises an exception
  except Exception, CatchableError:
    error "failure while initializing OnchainGroupManager",
      error = getCurrentExceptionMsg()
    quit(QuitFailure)

  # 4. register on-chain
  try:
    let registerResult =
      waitFor groupManager.register(credential, conf.userMessageLimit)
    if registerResult.isErr():
      error "Failed to register on-chain", error = registerResult.error
      quit(QuitFailure)
  except Exception, CatchableError:
    error "failure while registering credentials on-chain",
      error = getCurrentExceptionMsg()
    quit(QuitFailure)

  info "Transaction hash", txHash = groupManager.registrationTxHash.get()

  info "Your membership has been registered on-chain.",
    chainId = $groupManager.chainId,
    contractAddress = conf.ethContractAddress,
    membershipIndex = groupManager.membershipIndex.get()
  info "Your user message limit is", userMessageLimit = conf.userMessageLimit

  # 5. write to keystore
  let keystoreCred = KeystoreMembership(
    membershipContract: MembershipContract(
      chainId: $groupManager.chainId, address: conf.ethContractAddress
    ),
    treeIndex: groupManager.membershipIndex.get(),
    identityCredential: credential,
    userMessageLimit: conf.userMessageLimit,
  )

  addMembershipCredentials(conf.credPath, keystoreCred, conf.credPassword, RLNAppInfo).isOkOr:
    error "failed to persist credentials", error = error
    quit(QuitFailure)

  info "credentials persisted", path = conf.credPath

  try:
    waitFor groupManager.stop()
  except CatchableError:
    error "failure while stopping OnchainGroupManager", error = getCurrentExceptionMsg()
    quit(QuitSuccess) # 0 because we already registered on-chain
  quit(QuitSuccess)
