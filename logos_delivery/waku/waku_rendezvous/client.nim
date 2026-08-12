{.push raises: [].}

import
  std/[sequtils, tables],
  results,
  chronos,
  chronicles,
  libp2p/protocols/rendezvous,
  libp2p/crypto/curve25519,
  libp2p/switch

import metrics except collect

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/waku_core/codecs,
  ./common,
  ./waku_peer_record

logScope:
  topics = "waku rendezvous client"

declarePublicCounter logos_delivery_rendezvous_peer_found,
  "total number of peers found via rendezvous"

type WakuRendezVousClient* = ref object
  switch: Switch
  peerManager: PeerManager
  clusterId: uint16
  requestInterval: timer.Duration
  periodicRequestFut: Future[void]
  # Internal rendezvous instance for making requests
  rdv: GenericRendezVous[WakuPeerRecord]

const MaxSimultanesousAdvertisements = 5
const RendezVousLookupInterval = 10.seconds

proc requestAll*(
    self: WakuRendezVousClient
): Future[Result[void, string]] {.async: (raises: []).} =
  trace "Waku rendezvous client requests started"

  let namespace = computeMixNamespace(self.clusterId)

  # Get a random WakuRDV peer
  let rpi = self.peerManager.selectPeer(WakuRendezVousCodec).valueOr:
    return err("could not get a peer supporting WakuRendezVousCodec")

  var records: seq[WakuPeerRecord]
  try:
    # Use the libp2p rendezvous request method
    records = await self.rdv.request(
      Opt.some(namespace), Opt.some(PeersRequestedCount), Opt.some(@[rpi.peerId])
    )
  except CatchableError as e:
    return err("rendezvous request failed: " & e.msg)

  trace "Waku rendezvous client request got peers", count = records.len
  for record in records:
    if not self.switch.peerStore.peerExists(record.peerId):
      logos_delivery_rendezvous_peer_found.inc()
    if record.mixKey.len == 0 or record.peerId == self.switch.peerInfo.peerId:
      continue
    trace "adding peer from rendezvous",
      peerId = record.peerId, addresses = $record.addresses, mixKey = record.mixKey
    let rInfo = RemotePeerInfo.init(
      record.peerId,
      record.addresses,
      mixPubKey = Opt.some(intoCurve25519Key(fromHex(record.mixKey))),
    )
    self.peerManager.addPeer(rInfo)

  trace "Waku rendezvous client request finished"

  return ok()

proc periodicRequests(self: WakuRendezVousClient) {.async.} =
  debug "Waku rendezvous periodic requests started", interval = self.requestInterval

  # infinite loop
  while true:
    await sleepAsync(self.requestInterval)

    (await self.requestAll()).isOkOr:
      debug "Waku rendezvous requests failed", error = error

    # Exponential backoff

#[    TODO: Reevaluate for mix, maybe be aggresive in the start until a sizeable pool is built and then backoff
    self.requestInterval += self.requestInterval

    if self.requestInterval >= 1.days:
      break ]#

proc new*(
    T: type WakuRendezVousClient,
    switch: Switch,
    peerManager: PeerManager,
    clusterId: uint16,
): Result[T, string] {.raises: [].} =
  # Create a minimal GenericRendezVous instance for client-side requests
  # We don't need the full server functionality, just the request method
  let rng = newRng()
  let rdv = GenericRendezVous[WakuPeerRecord](
    switch: switch,
    rng: rng,
    sema: newAsyncSemaphore(MaxSimultanesousAdvertisements),
    config: RendezVousConfig(
      minDuration: rendezvous.MinimumAcceptedDuration,
      maxDuration: rendezvous.MaximumDuration,
      minTTL: rendezvous.MinimumAcceptedDuration.seconds.uint64,
      maxTTL: rendezvous.MaximumDuration.seconds.uint64,
    ),
    peers: @[], # Will be populated from selectPeer calls
    cookiesSaved: initTable[PeerId, Table[string, seq[byte]]](),
    peerRecordValidator: checkWakuPeerRecord,
  )

  # Set codec separately as it's inherited from LPProtocol
  rdv.codec = WakuRendezVousCodec

  let client = T(
    switch: switch,
    peerManager: peerManager,
    clusterId: clusterId,
    requestInterval: RendezVousLookupInterval,
    rdv: rdv,
  )

  info "Waku rendezvous client initialized", clusterId = clusterId

  return ok(client)

proc start*(self: WakuRendezVousClient) {.async: (raises: []).} =
  self.periodicRequestFut = self.periodicRequests()
  info "Waku rendezvous client started"

proc stopWait*(self: WakuRendezVousClient) {.async: (raises: []).} =
  if not self.periodicRequestFut.isNil():
    await self.periodicRequestFut.cancelAndWait()

  info "Waku rendezvous client stopped"
