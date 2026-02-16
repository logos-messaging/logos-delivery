{.push raises: [].}

import chronicles, std/[options, sequtils], chronos, results, metrics

import
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p/protocols/mix,
  libp2p/protocols/mix/mix_node,
  libp2p/protocols/mix/mix_protocol,
  libp2p/protocols/mix/mix_metrics,
  libp2p/protocols/mix/delay_strategy,
  libp2p/protocols/mix/spam_protection,
  libp2p/[multiaddress, multicodec, peerid, peerinfo],
  eth/common/keys

import
  waku/node/peer_manager,
  waku/waku_core,
  waku/waku_enr,
  waku/node/peer_manager/waku_peer_store,
  mix_rln_spam_protection,
  waku/waku_relay,
  waku/common/nimchronos

logScope:
  topics = "waku mix"

const minMixPoolSize = 4

type
  PublishMessage* = proc(message: WakuMessage): Future[Result[void, string]] {.
    async, gcsafe, raises: []
  .}

  WakuMix* = ref object of MixProtocol
    peerManager*: PeerManager
    clusterId: uint16
    pubKey*: Curve25519Key
    mixRlnSpamProtection*: MixRlnSpamProtection
    publishMessage*: PublishMessage

  WakuMixResult*[T] = Result[T, string]

  MixNodePubInfo* = object
    multiAddr*: string
    pubKey*: Curve25519Key

proc processBootNodes(
    bootnodes: seq[MixNodePubInfo], peermgr: PeerManager, mix: WakuMix
) =
  var count = 0
  for node in bootnodes:
    let (peerId, networkAddr) = parseFullAddress(node.multiAddr).valueOr:
      error "Failed to parse multiaddress", multiAddr = node.multiAddr, error = error
      continue
    var peerPubKey: crypto.PublicKey
    if not peerId.extractPublicKey(peerPubKey):
      warn "Failed to extract public key from peerId, skipping node", peerId = peerId
      continue

    if peerPubKey.scheme != PKScheme.Secp256k1:
      warn "Peer public key is not Secp256k1, skipping node",
        peerId = peerId, scheme = peerPubKey.scheme
      continue

    let multiAddr = MultiAddress.init(node.multiAddr).valueOr:
      error "Failed to parse multiaddress", multiAddr = node.multiAddr, error = error
      continue

    let mixPubInfo = MixPubInfo.init(peerId, multiAddr, node.pubKey, peerPubKey.skkey)
    mix.nodePool.add(mixPubInfo)
    count.inc()

    peermgr.addPeer(
      RemotePeerInfo.init(peerId, @[networkAddr], mixPubKey = some(node.pubKey))
    )
  mix_pool_size.set(count)
  debug "using mix bootstrap nodes ", count = count

proc new*(
    T: type WakuMix,
    nodeAddr: string,
    peermgr: PeerManager,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    bootnodes: seq[MixNodePubInfo],
    publishMessage: PublishMessage,
    userMessageLimit: Option[int] = none(int),
): WakuMixResult[T] =
  let mixPubKey = public(mixPrivKey)
  trace "mixPubKey", mixPubKey = mixPubKey
  let nodeMultiAddr = MultiAddress.init(nodeAddr).valueOr:
    return err("failed to parse mix node address: " & $nodeAddr & ", error: " & error)
  let localMixNodeInfo = initMixNodeInfo(
    peermgr.switch.peerInfo.peerId, nodeMultiAddr, mixPubKey, mixPrivKey,
    peermgr.switch.peerInfo.publicKey.skkey, peermgr.switch.peerInfo.privateKey.skkey,
  )
  if bootnodes.len < minMixPoolSize:
    warn "publishing with mix won't work until atleast 3 mix nodes in node pool"

  # Initialize spam protection with persistent credentials
  # Use peerID in keystore path so multiple peers can run from same directory
  # Tree path is shared across all nodes to maintain the full membership set
  let peerId = peermgr.switch.peerInfo.peerId
  var spamProtectionConfig = defaultConfig()
  spamProtectionConfig.keystorePath = "rln_keystore_" & $peerId & ".json"
  spamProtectionConfig.keystorePassword = "mix-rln-password"
  if userMessageLimit.isSome():
    spamProtectionConfig.userMessageLimit = userMessageLimit.get()
  # rlnResourcesPath left empty to use bundled resources (via "tree_height_/" placeholder)

  let spamProtection = newMixRlnSpamProtection(spamProtectionConfig).valueOr:
    return err("failed to create spam protection: " & error)

  var m = WakuMix(
    peerManager: peermgr,
    clusterId: clusterId,
    pubKey: mixPubKey,
    mixRlnSpamProtection: spamProtection,
    publishMessage: publishMessage,
  )
  procCall MixProtocol(m).init(
    localMixNodeInfo,
    peermgr.switch,
    spamProtection = Opt.some(SpamProtection(spamProtection)),
    delayStrategy =
      ExponentialDelayStrategy.new(meanDelayMs = 100, rng = crypto.newRng()),
  )

  processBootNodes(bootnodes, peermgr, m)

  if m.nodePool.len < minMixPoolSize:
    warn "publishing with mix won't work until atleast 3 mix nodes in node pool"

  return ok(m)

proc poolSize*(mix: WakuMix): int =
  mix.nodePool.len

proc setupSpamProtectionCallbacks(mix: WakuMix) =
  ## Set up the publish callback for spam protection coordination.
  ## This enables the plugin to broadcast membership updates and proof metadata
  ## via Waku relay.
  if mix.publishMessage.isNil():
    warn "PublishMessage callback not available, spam protection coordination disabled"
    return

  let publishCallback: PublishCallback = proc(
      contentTopic: string, data: seq[byte]
  ) {.async.} =
    # Create a WakuMessage for the coordination data
    let msg = WakuMessage(
      payload: data,
      contentTopic: contentTopic,
      ephemeral: true, # Coordination messages don't need to be stored
      timestamp: getNowInNanosecondTime(),
    )

    # Delegate to node's publish API which handles topic derivation and relay publishing
    let res = await mix.publishMessage(msg)
    if res.isErr():
      warn "Failed to publish spam protection coordination message",
        contentTopic = contentTopic, error = res.error
      return

    trace "Published spam protection coordination message", contentTopic = contentTopic

  mix.mixRlnSpamProtection.setPublishCallback(publishCallback)
  trace "Spam protection publish callback configured"

proc handleMessage*(
    mix: WakuMix, pubsubTopic: PubsubTopic, message: WakuMessage
) {.async, gcsafe.} =
  ## Handle incoming messages for spam protection coordination.
  ## This should be called from the relay handler for coordination content topics.
  if mix.mixRlnSpamProtection.isNil():
    return

  let contentTopic = message.contentTopic

  if contentTopic == mix.mixRlnSpamProtection.getMembershipContentTopic():
    # Handle membership update
    let res = await mix.mixRlnSpamProtection.handleMembershipUpdate(message.payload)
    if res.isErr:
      warn "Failed to handle membership update", error = res.error
    else:
      trace "Handled membership update"

      # Persist tree after membership changes (temporary solution)
      # TODO: Replace with proper persistence strategy (e.g., periodic snapshots)
      let saveRes = mix.mixRlnSpamProtection.saveTree()
      if saveRes.isErr:
        debug "Failed to save tree after membership update", error = saveRes.error
      else:
        trace "Saved tree after membership update"
  elif contentTopic == mix.mixRlnSpamProtection.getProofMetadataContentTopic():
    # Handle proof metadata for network-wide spam detection
    let res = mix.mixRlnSpamProtection.handleProofMetadata(message.payload)
    if res.isErr:
      warn "Failed to handle proof metadata", error = res.error
    else:
      trace "Handled proof metadata"

proc getSpamProtectionContentTopics*(mix: WakuMix): seq[string] =
  ## Get the content topics used by spam protection for coordination.
  ## Use these to set up relay subscriptions.
  if mix.mixRlnSpamProtection.isNil():
    return @[]
  return mix.mixRlnSpamProtection.getContentTopics()

proc saveSpamProtectionTree*(mix: WakuMix): Result[void, string] =
  ## Save the spam protection membership tree to disk.
  ## This allows preserving the tree state across restarts.
  if mix.mixRlnSpamProtection.isNil():
    return err("Spam protection not initialized")

  mix.mixRlnSpamProtection.saveTree().mapErr(
    proc(e: string): string =
      e
  )

proc loadSpamProtectionTree*(mix: WakuMix): Result[void, string] =
  ## Load the spam protection membership tree from disk.
  ## Call this before init() to restore tree state from previous runs.
  ## TODO: This is a temporary solution. Ideally nodes should sync tree state
  ## via a store query for historical membership messages or via dedicated
  ## tree sync protocol.
  if mix.mixRlnSpamProtection.isNil():
    return err("Spam protection not initialized")

  mix.mixRlnSpamProtection.loadTree().mapErr(
    proc(e: string): string =
      e
  )

method start*(mix: WakuMix) {.async.} =
  info "starting waku mix protocol"

  # Set up spam protection callbacks and start
  if not mix.mixRlnSpamProtection.isNil():
    # Initialize spam protection (MixProtocol.init() does NOT call init() on the plugin)
    let initRes = await mix.mixRlnSpamProtection.init()
    if initRes.isErr:
      error "Failed to initialize spam protection", error = initRes.error
    else:
      # Load existing tree to sync with other members
      # This should be done after init() (which loads credentials)
      # but before registerSelf() (which adds us to the tree)
      let loadRes = mix.mixRlnSpamProtection.loadTree()
      if loadRes.isErr:
        debug "No existing tree found or failed to load, starting fresh",
          error = loadRes.error
      else:
        debug "Loaded existing spam protection membership tree from disk"

      # Restore our credentials to the tree (after tree load, whether it succeeded or not)
      # This ensures our member is in the tree if we have an index from keystore
      let restoreRes = mix.mixRlnSpamProtection.restoreCredentialsToTree()
      if restoreRes.isErr:
        error "Failed to restore credentials to tree", error = restoreRes.error

      # Set up publish callback (must be before start so registerSelf can use it)
      mix.setupSpamProtectionCallbacks()

      let startRes = await mix.mixRlnSpamProtection.start()
      if startRes.isErr:
        error "Failed to start spam protection", error = startRes.error
      else:
        # Register self to broadcast membership to the network
        let registerRes = await mix.mixRlnSpamProtection.registerSelf()
        if registerRes.isErr:
          error "Failed to register spam protection credentials",
            error = registerRes.error
        else:
          debug "Registered spam protection credentials", index = registerRes.get()

        # Save tree to persist membership state
        let saveRes = mix.mixRlnSpamProtection.saveTree()
        if saveRes.isErr:
          warn "Failed to save spam protection tree", error = saveRes.error
        else:
          trace "Saved spam protection tree to disk"

method stop*(mix: WakuMix) {.async.} =
  # Stop spam protection
  if not mix.mixRlnSpamProtection.isNil():
    await mix.mixRlnSpamProtection.stop()
    debug "Spam protection stopped"

# Mix Protocol
