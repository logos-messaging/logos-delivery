{.push raises: [].}

import
  std/[sugar, options, sequtils, tables],
  results,
  chronos,
  chronicles,
  stew/byteutils,
  libp2p/protocols/rendezvous,
  libp2p/protocols/rendezvous/protobuf,
  libp2p/utils/semaphore,
  libp2p/utils/offsettedseq,
  libp2p/crypto/curve25519,
  libp2p/switch,
  libp2p/utility

import metrics except collect

import
  ../node/peer_manager,
  ../common/callbacks,
  ../waku_enr/capabilities,
  ../waku_core/peers,
  ../waku_core/codecs,
  ./common,
  ./waku_peer_record

logScope:
  topics = "waku rendezvous"

type WakuRendezVous* = ref object of GenericRendezVous[WakuPeerRecord]
  peerManager: PeerManager
  clusterId: uint16
  getShards: GetShards
  getCapabilities: GetCapabilities
  getPeerRecord: GetWakuPeerRecord

  registrationInterval: timer.Duration
  periodicRegistrationFut: Future[void]

const MaximumNamespaceLen = 255

method discover*(
    self: WakuRendezVous, conn: Connection, d: Discover
) {.async: (raises: [CancelledError, LPStreamError]).} =
  # Override discover method to avoid collect macro generic instantiation issues
  trace "Received Discover", peerId = conn.peerId, ns = d.ns
  await procCall GenericRendezVous[WakuPeerRecord](self).discover(conn, d)

proc advertise*(
    self: WakuRendezVous,
    namespace: string,
    peers: seq[PeerId],
    ttl: timer.Duration = self.minDuration,
): Future[Result[void, string]] {.async: (raises: []).} =
  trace "advertising via waku rendezvous",
    namespace = namespace, ttl = ttl, peers = $peers, peerRecord = $self.getPeerRecord()
  let se = SignedPayload[WakuPeerRecord].init(
    self.switch.peerInfo.privateKey, self.getPeerRecord()
  ).valueOr:
    return
      err("rendezvous advertisement failed: Failed to sign Waku Peer Record: " & $error)
  let sprBuff = se.encode().valueOr:
    return err("rendezvous advertisement failed: Wrong Signed Peer Record: " & $error)

  # rendezvous.advertise expects already opened connections
  # must dial first

  var futs = collect(newSeq):
    for peerId in peers:
      self.peerManager.dialPeer(peerId, self.codec)

  let dialCatch = catch:
    await allFinished(futs)

  if dialCatch.isErr():
    return err("advertise: " & dialCatch.error.msg)

  futs = dialCatch.get()

  let conns = collect(newSeq):
    for fut in futs:
      let catchable = catch:
        fut.read()

      if catchable.isErr():
        warn "a rendezvous dial failed", cause = catchable.error.msg
        continue

      let connOpt = catchable.get()

      let conn = connOpt.valueOr:
        continue

      conn

  if conns.len == 0:
    return err("could not establish any connections to rendezvous peers")

  try:
    await self.advertise(namespace, ttl, peers, sprBuff)
  except Exception as e:
    return err("rendezvous advertisement failed: " & e.msg)
  finally:
    for conn in conns:
      await conn.close()
  return ok()

proc advertiseAll*(
    self: WakuRendezVous
): Future[Result[void, string]] {.async: (raises: []).} =
  trace "waku rendezvous advertisements started"

  let rpi = self.peerManager.selectPeer(self.codec).valueOr:
    return err("could not get a peer supporting RendezVousCodec")

  let namespace = computeMixNamespace(self.clusterId)

  # Advertise yourself on that peer
  let res = await self.advertise(namespace, @[rpi.peerId])

  trace "waku rendezvous advertisements finished"

  return res

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

proc new*(
    T: type WakuRendezVous,
    switch: Switch,
    peerManager: PeerManager,
    clusterId: uint16,
    getShards: GetShards,
    getCapabilities: GetCapabilities,
    getPeerRecord: GetWakuPeerRecord,
): Result[T, string] {.raises: [].} =
  let rng = newRng()
  let wrv = T(
    rng: rng,
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](),
    expiredDT: Moment.now() - 1.days,
    sema: newAsyncSemaphore(SemaphoreDefaultSize),
    minDuration: rendezvous.MinimumAcceptedDuration,
    maxDuration: rendezvous.MaximumDuration,
    minTTL: rendezvous.MinimumAcceptedDuration.seconds.uint64,
    maxTTL: rendezvous.MaximumDuration.seconds.uint64,
    peerRecordValidator: checkWakuPeerRecord,
  )

  wrv.peerManager = peerManager
  wrv.clusterId = clusterId
  wrv.getShards = getShards
  wrv.getCapabilities = getCapabilities
  wrv.registrationInterval = DefaultRegistrationInterval
  wrv.getPeerRecord = getPeerRecord
  wrv.switch = switch
  wrv.codec = WakuRendezVousCodec

  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let
        buf = await conn.readLp(4096)
        msg = Message.decode(buf).tryGet()
      case msg.msgType
      of MessageType.Register:
        #TODO: override this to store peers registered with us in peerstore with their info as well.
        await wrv.register(conn, msg.register.tryGet(), wrv.getPeerRecord())
      of MessageType.RegisterResponse:
        trace "Got an unexpected Register Response", response = msg.registerResponse
      of MessageType.Unregister:
        wrv.unregister(conn, msg.unregister.tryGet())
      of MessageType.Discover:
        await wrv.discover(conn, msg.discover.tryGet())
      of MessageType.DiscoverResponse:
        trace "Got an unexpected Discover Response", response = msg.discoverResponse
    except CancelledError as exc:
      trace "cancelled rendezvous handler"
      raise exc
    except CatchableError as exc:
      trace "exception in rendezvous handler", description = exc.msg
    finally:
      await conn.close()

  wrv.handler = handleStream

  info "waku rendezvous initialized",
    clusterId = clusterId,
    shards = getShards(),
    capabilities = getCapabilities(),
    wakuPeerRecord = getPeerRecord()

  return ok(wrv)

proc start*(self: WakuRendezVous) {.async: (raises: []).} =
  # Start the parent GenericRendezVous (starts the register deletion loop)
  if self.started:
    warn "waku rendezvous already started"
    return
  try:
    await procCall GenericRendezVous[WakuPeerRecord](self).start()
  except CancelledError as exc:
    error "failed to start GenericRendezVous", cause = exc.msg
    return
  # start registering forever
  self.periodicRegistrationFut = self.periodicRegistration()

  info "waku rendezvous discovery started"

proc stopWait*(self: WakuRendezVous) {.async: (raises: []).} =
  if not self.periodicRegistrationFut.isNil():
    await self.periodicRegistrationFut.cancelAndWait()

  # Stop the parent GenericRendezVous (stops the register deletion loop)
  await GenericRendezVous[WakuPeerRecord](self).stop()

  # Stop the parent GenericRendezVous (stops the register deletion loop)
  await GenericRendezVous[WakuPeerRecord](self).stop()

  info "waku rendezvous discovery stopped"
