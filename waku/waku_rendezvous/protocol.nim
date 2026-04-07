{.push raises: [].}

import
  std/[sugar, options],
  results,
  chronos,
  chronicles,
  metrics,
  libp2p/protocols/rendezvous,
  libp2p/switch,
  libp2p/utility

import
  ../node/peer_manager,
  ../common/callbacks,
  ../waku_enr/capabilities,
  ../waku_core/peers,
  ../waku_core/topics,
  ../waku_core/topics/pubsub_topic,
  ./common,
  waku/common/benchmark_metrics

logScope:
  topics = "waku rendezvous"

declarePublicCounter rendezvousPeerFoundTotal,
  "total number of peers found via rendezvous"

type WakuRendezVous* = ref object
  rendezvous: Rendezvous
  peerManager: PeerManager
  clusterId: uint16
  getShards: GetShards
  getCapabilities: GetCapabilities

  registrationInterval: timer.Duration
  periodicRegistrationFut: Future[void]

  requestInterval: timer.Duration
  periodicRequestFut: Future[void]

proc batchAdvertise*(
    self: WakuRendezVous,
    namespace: string,
    ttl: Duration = DefaultRegistrationTTL,
    peers: seq[PeerId],
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Register with all rendezvous peers under a namespace

  # rendezvous.advertise expects already opened connections
  # must dial first
  var futs = collect(newSeq):
    for peerId in peers:
      self.peerManager.dialPeer(peerId, RendezVousCodec)

  let dialCatch = catch:
    await allFinished(futs)

  futs = dialCatch.valueOr:
    return err("batchAdvertise: " & error.msg)

  let conns = collect(newSeq):
    for fut in futs:
      let catchable = catch:
        fut.read()

      catchable.isOkOr:
        warn "a rendezvous dial failed", cause = error.msg
        continue

      let connOpt = catchable.get()

      let conn = connOpt.valueOr:
        continue

      conn

  let advertCatch = catch:
    await self.rendezvous.advertise(namespace, Opt.some(ttl))

  for conn in conns:
    await conn.close()

  advertCatch.isOkOr:
    return err("batchAdvertise: " & error.msg)

  return ok()

proc batchRequest*(
    self: WakuRendezVous,
    namespace: string,
    count: int = DiscoverLimit,
    peers: seq[PeerId],
): Future[Result[seq[PeerRecord], string]] {.async: (raises: []).} =
  ## Request all records from all rendezvous peers matching a namespace

  benchmarkPoint("waku_rendezvous", "batchRequest")

  # rendezvous.request expects already opened connections
  # must dial first
  var futs = collect(newSeq):
    for peerId in peers:
      self.peerManager.dialPeer(peerId, RendezVousCodec)

  let dialCatch = catch:
    await allFinished(futs)

  futs = dialCatch.valueOr:
    return err("batchRequest: " & error.msg)

  let conns = collect(newSeq):
    for fut in futs:
      let catchable = catch:
        fut.read()

      catchable.isOkOr:
        warn "a rendezvous dial failed", cause = error.msg
        continue

      let connOpt = catchable.get()

      let conn = connOpt.valueOr:
        continue

      conn

  let reqCatch = catch:
    await self.rendezvous.request(Opt.some(namespace), Opt.some(count), Opt.some(peers))

  for conn in conns:
    await conn.close()

  reqCatch.isOkOr:
    return err("batchRequest: " & error.msg)

  return ok(reqCatch.get())

proc advertiseAll(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  info "waku rendezvous advertisements started"

  benchmarkPoint("waku_rendezvous", "advertiseAll")
  let shards = self.getShards()

  let futs = collect(newSeq):
    for shardId in shards:
      # Get a random RDV peer for that shard

      let pubsub =
        toPubsubTopic(RelayShard(clusterId: self.clusterId, shardId: shardId))

      let rpi = self.peerManager.selectPeer(RendezVousCodec, some(pubsub)).valueOr:
        continue

      let namespace = computeNamespace(self.clusterId, shardId)

      # Advertise yourself on that peer
      self.batchAdvertise(namespace, DefaultRegistrationTTL, @[rpi.peerId])

  if futs.len < 1:
    return err("could not get a peer supporting RendezVousCodec")

  let catchable = catch:
    await allFinished(futs)

  catchable.isOkOr:
    return err(error.msg)

  for fut in catchable.get():
    if fut.failed():
      warn "a rendezvous advertisement failed", cause = fut.error.msg

  info "waku rendezvous advertisements finished"

  return ok()

proc initialRequestAll*(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  info "waku rendezvous initial requests started"

  benchmarkPoint("waku_rendezvous", "initialRequestAll")
  let shards = self.getShards()

  let futs = collect(newSeq):
    for shardId in shards:
      let namespace = computeNamespace(self.clusterId, shardId)
      # Get a random RDV peer for that shard
      let rpi = self.peerManager.selectPeer(
        RendezVousCodec,
        some(toPubsubTopic(RelayShard(clusterId: self.clusterId, shardId: shardId))),
      ).valueOr:
        continue

      # Ask for peer records for that shard
      self.batchRequest(namespace, PeersRequestedCount, @[rpi.peerId])

  if futs.len < 1:
    return err("could not get a peer supporting RendezVousCodec")

  let catchable = catch:
    await allFinished(futs)

  catchable.isOkOr:
    return err(error.msg)

  for fut in catchable.get():
    if fut.failed():
      warn "a rendezvous request failed", cause = fut.error.msg
    elif fut.finished():
      let res = fut.value()

      let records = res.valueOr:
        warn "a rendezvous request failed", cause = $error
        continue

      for record in records:
        rendezvousPeerFoundTotal.inc()
        self.peerManager.addPeer(record)

  info "waku rendezvous initial request finished"

  return ok()

proc periodicRegistration(self: WakuRendezVous) {.async.} =
  info "waku rendezvous periodic registration started",
    interval = self.registrationInterval

  # infinite loop
  while true:
    await sleepAsync(self.registrationInterval)

    (await self.advertiseAll()).isOkOr:
      info "waku rendezvous advertisements failed", error = error

      if self.registrationInterval > MaxRegistrationInterval:
        self.registrationInterval = MaxRegistrationInterval
      else:
        self.registrationInterval += self.registrationInterval

    # Back to normal interval if no errors
    self.registrationInterval = DefaultRegistrationInterval

proc periodicRequests(self: WakuRendezVous) {.async.} =
  info "waku rendezvous periodic requests started", interval = self.requestInterval

  # infinite loop
  while true:
    (await self.initialRequestAll()).isOkOr:
      error "waku rendezvous requests failed", error = error

    await sleepAsync(self.requestInterval)

    # Exponential backoff
    self.requestInterval += self.requestInterval

    if self.requestInterval >= 1.days:
      break

proc new*(
    T: type WakuRendezVous,
    switch: Switch,
    peerManager: PeerManager,
    clusterId: uint16,
    getShards: GetShards,
    getCapabilities: GetCapabilities,
): Result[T, string] {.raises: [].} =
  let rvCatchable = catch:
    RendezVous.new(switch = switch, minDuration = DefaultRegistrationTTL)

  let rv = rvCatchable.valueOr:
    return err(error.msg)

  let mountCatchable = catch:
    switch.mount(rv)

  mountCatchable.isOkOr:
    return err(error.msg)

  var wrv = WakuRendezVous()
  wrv.rendezvous = rv
  wrv.peerManager = peerManager
  wrv.clusterId = clusterId
  wrv.getShards = getShards
  wrv.getCapabilities = getCapabilities
  wrv.registrationInterval = DefaultRegistrationInterval
  wrv.requestInterval = DefaultRequestsInterval

  info "waku rendezvous initialized",
    clusterId = clusterId, shards = getShards(), capabilities = getCapabilities()

  return ok(wrv)

proc start*(self: WakuRendezVous) {.async: (raises: []).} =
  # start registering forever
  self.periodicRegistrationFut = self.periodicRegistration()

  self.periodicRequestFut = self.periodicRequests()

  info "waku rendezvous discovery started"

proc stopWait*(self: WakuRendezVous) {.async: (raises: []).} =
  if not self.periodicRegistrationFut.isNil():
    await self.periodicRegistrationFut.cancelAndWait()

  if not self.periodicRequestFut.isNil():
    await self.periodicRequestFut.cancelAndWait()

  info "waku rendezvous discovery stopped"
