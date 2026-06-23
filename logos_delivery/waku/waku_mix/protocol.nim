import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import chronicles, std/[options, sequtils], chronos, results, metrics

import
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p_mix,
  libp2p_mix/mix_node,
  libp2p_mix/mix_protocol,
  libp2p_mix/mix_metrics,
  libp2p_mix/delay_strategy,
  libp2p_mix/spam_protection,
  libp2p_mix/cover_traffic,
  libp2p/[multiaddress, multicodec, peerid, peerinfo],
  eth/common/keys

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_enr,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  mix_rln_spam_protection,
  logos_delivery/waku/waku_relay,
  logos_delivery/waku/common/nimchronos

logScope:
  topics = "waku mix"

const minMixPoolSize* = 4

# Waku-side cover-traffic defaults for the no-RLN path (i.e. when
# `disableSpamProtection = true`). When RLN is enabled, both values are
# overridden below by the spam-protection plugin's config so cover
# emission can never outpace proof minting.
#
# Emission rate is given by:
#     emissionInterval = epochDuration * (1 + PathLength) / totalSlots
# With PathLength = 3 and the values below: 60s * 4 / 40 = 6s, i.e. ~10
# cover packets per minute per node. Tuned to be light enough not to
# saturate a small testnet while still exercising cover-traffic flow.
const
  WakuCoverTrafficTotalSlots = 40
    ## Cover-traffic budget per epoch when RLN is disabled (slot pool size).
  WakuCoverTrafficEpochDuration = 60.seconds
    ## Cover-traffic epoch duration when RLN is disabled. Slot pool resets
    ## at this cadence; the internal epoch timer fires on this interval.

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
    dosRegistrationTask: Future[void]
      ## Background task that retries DoS-protection self-registration until
      ## it succeeds. nil until kicked off via registerDoSProtectionWithNetwork;
      ## cancelled in stop().

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
    T: typedesc[WakuMix],
    nodeAddr: string,
    peermgr: PeerManager,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    bootnodes: seq[MixNodePubInfo],
    publishMessage: PublishMessage,
    userMessageLimit: Option[int] = none(int),
    disableSpamProtection: bool = false,
    disableCoverTraffic: bool = false,
): WakuMixResult[T] =
  let mixPubKey = public(mixPrivKey)
  trace "mixPubKey", mixPubKey = mixPubKey
  let nodeMultiAddr = MultiAddress.init(nodeAddr).valueOr:
    return err("failed to parse mix node address: " & $nodeAddr & ", error: " & error)
  let localMixNodeInfo = initMixNodeInfo(
    peermgr.switch.peerInfo.peerId, nodeMultiAddr, mixPubKey, mixPrivKey,
    peermgr.switch.peerInfo.publicKey.skkey, peermgr.switch.peerInfo.privateKey.skkey,
  )

  # Start with waku's no-RLN cover-traffic defaults. The spam-protection
  # branch below overrides these from the plugin's config so cover emission
  # can't outpace proof minting when RLN is on.
  var ctTotalSlots = WakuCoverTrafficTotalSlots
  var ctEpochDuration = WakuCoverTrafficEpochDuration

  var spamProtectionOpt = default(Opt[SpamProtection])
  if not disableSpamProtection:
    # Initialize spam protection with persistent credentials
    let peerId = peermgr.switch.peerInfo.peerId
    var spamProtectionConfig = defaultConfig()
    spamProtectionConfig.keystorePath = "rln_keystore_" & $peerId & ".json"
    spamProtectionConfig.keystorePassword = "mix-rln-password"
    if userMessageLimit.isSome():
      spamProtectionConfig.userMessageLimit = userMessageLimit.get()

    ctTotalSlots = spamProtectionConfig.userMessageLimit
    ctEpochDuration = spamProtectionConfig.epochDurationSeconds.int.seconds

    let spamProtection = MixRlnSpamProtection.new(spamProtectionConfig).valueOr:
      return err("failed to create spam protection: " & error)
    spamProtectionOpt = Opt.some(SpamProtection(spamProtection))
  else:
    info "mix spam protection disabled"

  var coverTrafficOpt = default(Opt[CoverTraffic])
  if not disableCoverTraffic:
    let ct = ConstantRateCoverTraffic.new(
      totalSlots = ctTotalSlots,
      epochDuration = ctEpochDuration,
      useInternalEpochTimer = disableSpamProtection,
    )
    coverTrafficOpt = Opt.some(CoverTraffic(ct))
  else:
    info "mix cover traffic disabled"

  var mixRlnSpam: MixRlnSpamProtection
  if spamProtectionOpt.isSome():
    mixRlnSpam = MixRlnSpamProtection(spamProtectionOpt.get())

  var m = WakuMix(
    peerManager: peermgr,
    clusterId: clusterId,
    pubKey: mixPubKey,
    publishMessage: publishMessage,
    mixRlnSpamProtection: mixRlnSpam,
  )
  procCall MixProtocol(m).init(
    localMixNodeInfo,
    peermgr.switch,
    spamProtection = spamProtectionOpt,
    delayStrategy = Opt.some(
      DelayStrategy(
        ExponentialDelayStrategy.new(meanDelay = 100, rng = crypto.newRng())
      )
    ),
    coverTraffic = coverTrafficOpt,
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
  if mix.mixRlnSpamProtection.isNil():
    return
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
  ## Local-only mix protocol initialization. Does NOT touch the network.
  ## The network-dependent self-registration broadcast is handled separately
  ## by registerDoSProtectionWithNetwork so that this proc can run before
  ## peers are connected without blocking on relay startup.
  info "starting waku mix protocol"

  if not mix.mixRlnSpamProtection.isNil():
    # Initialize spam protection (MixProtocol.init() does NOT call init() on the plugin)
    let initRes = await mix.mixRlnSpamProtection.init()
    if initRes.isErr:
      error "Failed to initialize spam protection", error = initRes.error
      return

    # Load existing tree to sync with other members.
    # Should be done after init() (which loads credentials) but before
    # registerSelf() (which adds us to the tree).
    let loadRes = mix.mixRlnSpamProtection.loadTree()
    if loadRes.isErr:
      debug "No existing tree found or failed to load, starting fresh",
        error = loadRes.error
    else:
      debug "Loaded existing spam protection membership tree from disk"

    # Restore our credentials to the tree (after tree load, whether it succeeded or not).
    # Ensures our member is in the tree if we have an index from keystore.
    let restoreRes = mix.mixRlnSpamProtection.restoreCredentialsToTree()
    if restoreRes.isErr:
      error "Failed to restore credentials to tree", error = restoreRes.error

    # Set up publish callback. Must be before the network-side registration so
    # the plugin's groupManager.register can broadcast the membership update.
    mix.setupSpamProtectionCallbacks()

    let startRes = await mix.mixRlnSpamProtection.start()
    if startRes.isErr:
      error "Failed to start spam protection", error = startRes.error

  info "waku mix protocol started"

proc dosRegistrationRetryLoop(mix: WakuMix) {.async.} =
  ## Indefinitely retry the DoS-protection self-registration broadcast until
  ## it succeeds (or this task is cancelled by WakuMix.stop()). For nodes that
  ## already have a membership index in their keystore, registerSelf early-
  ## returns and the loop exits on the first attempt. For fresh nodes, the
  ## broadcast needs at least one relay peer subscribed to the membership
  ## topic to land — this loop survives transient "no peers yet" failures.
  ##
  ## TODO: Remove once RLN membership moves on-chain. With on-chain membership
  ## peers discover each other via the contract / a watcher rather than via a
  ## pubsub broadcast, so the retry loop (and the whole publishCallback path
  ## from registerSelf) becomes unnecessary.
  ##
  ## Retry pacing uses exponential backoff (5s, 10s, 20s, ..., capped at 5min)
  ## so persistent misconfiguration — e.g., relay never available — degrades
  ## to one log line every 5 minutes after the initial ramp instead of every
  ## 5 seconds forever.
  const InitialRetryDelay = chronos.seconds(5)
  const MaxRetryDelay = chronos.minutes(5)
  var delay = InitialRetryDelay
  while true:
    try:
      let registerRes = await mix.mixRlnSpamProtection.registerSelf()
      if registerRes.isOk():
        debug "DoS-protection self-registration succeeded", index = registerRes.get()
        # Persist tree only after a successful register — for fresh nodes this
        # captures the new index; for keystore nodes it's a harmless no-op.
        let saveRes = mix.mixRlnSpamProtection.saveTree()
        if saveRes.isErr:
          warn "Failed to save spam protection tree", error = saveRes.error
        else:
          trace "Saved spam protection tree to disk"
        return # success — exit the loop
      warn "DoS-protection self-registration failed, retrying",
        error = registerRes.error, nextDelay = delay
    except CancelledError as e:
      debug "DoS-protection registration loop cancelled"
      raise e
    except CatchableError as e:
      warn "DoS-protection registration raised, retrying",
        error = e.msg, nextDelay = delay
    await sleepAsync(delay)
    delay = min(delay * 2, MaxRetryDelay)

proc registerDoSProtectionWithNetwork*(mix: WakuMix) =
  ## Kick off an indefinite background task that broadcasts this node's
  ## DoS-protection (RLN) membership registration to other mix nodes via
  ## relay. Returns immediately so callers don't block on a possibly-slow
  ## broadcast. The task is cancelled when WakuMix.stop() is called.
  if mix.mixRlnSpamProtection.isNil():
    return
  # Guard against kicking off the retry loop when the plugin isn't actually
  # usable (e.g., mix.start()'s init/start steps failed). Without this check
  # the loop would spin forever logging "Plugin not initialized" warnings.
  if not mix.mixRlnSpamProtection.isReady():
    warn "Skipping DoS-protection registration: plugin not ready"
    return
  # Re-call safety: don't spawn a second loop if one is still in flight.
  if not mix.dosRegistrationTask.isNil and not mix.dosRegistrationTask.finished:
    debug "DoS-protection registration already in progress, skipping"
    return
  mix.dosRegistrationTask = mix.dosRegistrationRetryLoop()

method stop*(mix: WakuMix) {.async.} =
  # Cancel the in-flight DoS-protection registration retry loop, if any
  if not mix.dosRegistrationTask.isNil and not mix.dosRegistrationTask.finished:
    await mix.dosRegistrationTask.cancelAndWait()
  # Stop spam protection
  if not mix.mixRlnSpamProtection.isNil():
    await mix.mixRlnSpamProtection.stop()
    debug "Spam protection stopped"

# Mix Protocol
