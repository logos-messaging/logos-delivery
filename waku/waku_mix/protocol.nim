{.push raises: [].}

import chronicles, std/options, chronos, results, metrics

import
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p/protocols/mix,
  libp2p/protocols/mix/mix_node,
  libp2p/protocols/mix/mix_protocol,
  libp2p/protocols/mix/mix_metrics,
  libp2p/protocols/mix/delay_strategy,
  libp2p/[multiaddress, peerid, switch],
  libp2p/extended_peer_record,
  eth/common/keys

import
  waku/node/peer_manager,
  waku/waku_core,
  waku/waku_enr,
  waku/node/peer_manager/waku_peer_store,
  waku/discovery/waku_kademlia

logScope:
  topics = "waku mix"

const
  MinimumMixPoolSize = 4
  DefaultMixPoolMaintenanceInterval = chronos.seconds(10)

type WakuMix* = ref object of MixProtocol
  pubKey*: Curve25519Key
  targetMixPoolSize: int
  currentMixPoolSize: int
  maintenanceInterval: Duration
  maintenanceIntervalFut: Future[void]
  wakuKademlia: WakuKademlia

proc poolSize*(self: WakuMix): int =
  if self.nodePool.isNil():
    0
  else:
    self.nodePool.len()

proc mixPoolMaintenance(
    self: WakuMix, interval: Duration
) {.async: (raises: [CancelledError]).} =
  ## Periodic maintenance of the mix pool

  while true:
    await sleepAsync(interval)

    self.currentMixPoolSize = self.poolSize()
    mix_pool_size.set(self.currentMixPoolSize.int64)

    if self.currentMixPoolSize >= self.targetMixPoolSize:
      continue

    # Skip discovery if kademlia not available
    if self.wakuKademlia.isNil():
      debug "kademlia not available for mix peer discovery"
      continue

    debug "mix node pool below threshold, performing targeted lookup",
      currentPoolSize = self.currentMixPoolSize, threshold = self.targetMixPoolSize

    let mixPeers = await self.wakuKademlia.lookup(MixProtocolID)

    debug "mix peer discovery completed", discoveredPeers = mixPeers.len

proc new*(
    T: typedesc[WakuMix],
    mixPrivKey: Curve25519Key,
    nodeAddr: string,
    switch: Switch,
    targetMixPoolSize: int = MinimumMixPoolSize,
    maintenanceInterval: Duration = DefaultMixPoolMaintenanceInterval,
    wakuKademlia: WakuKademlia = nil,
): Result[T, string] =
  let mixPubKey = public(mixPrivKey)

  info "mixPubKey", mixPubKey = mixPubKey

  let nodeMultiAddr = MultiAddress.init(nodeAddr).valueOr:
    return err("failed to parse mix node address: " & $nodeAddr & ", error: " & error)

  let localMixNodeInfo = initMixNodeInfo(
    switch.peerInfo.peerId, nodeMultiAddr, mixPubKey, mixPrivKey,
    switch.peerInfo.publicKey.skkey, switch.peerInfo.privateKey.skkey,
  )

  let mix = WakuMix(
    pubKey: mixPubKey,
    targetMixPoolSize: targetMixPoolSize,
    currentMixPoolSize: 0,
    maintenanceInterval: maintenanceInterval,
    maintenanceIntervalFut: nil,
    wakuKademlia: wakuKademlia,
  )

  procCall MixProtocol(mix).init(
    localMixNodeInfo,
    switch,
    delayStrategy =
      ExponentialDelayStrategy.new(meanDelayMs = 50, rng = crypto.newRng()),
  )

  return ok(mix)

proc setKademlia*(self: WakuMix, wakuKademlia: WakuKademlia) =
  self.wakuKademlia = wakuKademlia

method start*(self: WakuMix) {.async.} =
  if self.started:
    warn "Starting Waku Mix twice"
    return

  info "Starting Waku Mix"

  await procCall start(MixProtocol(self))

  self.maintenanceIntervalFut = self.mixPoolMaintenance(self.maintenanceInterval)

  info "Waku Mix Started"

method stop*(self: WakuMix) {.async.} =
  if not self.started:
    return

  info "Stopping Waku Mix"

  if not self.maintenanceIntervalFut.isNil():
    self.maintenanceIntervalFut.cancelSoon()
    self.maintenanceIntervalFut = nil

  await procCall stop(MixProtocol(self))

  info "Successfully stopped Waku Mix"
