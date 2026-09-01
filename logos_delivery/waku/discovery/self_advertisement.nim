{.push raises: [].}

## Advertising this node on the kademlia service-discovery network.
##
## Every participating node registers interest in `/logos/delivery`, and a node
## that serves anything (relay, store, filter, lightpush) also advertises
## itself under it. That gives the network one place to look for its own
## members, instead of each node only being findable through whichever
## protocol-specific service it happens to run.
##
## Which backends take part is decided by what they declare, not by naming
## them: a backend receives this only if its `keyKinds` includes `svc`. That is
## true of both kademlia hosts -- in-process and plugin -- and false of discv5,
## whose advertising means mutating our own ENR and which rejects `svc:` keys
## outright.

import chronos, chronicles, results
import libp2p_mix/mix_protocol
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/waku_enr/capabilities

logScope:
  topics = "waku discovery advertise"

const SvcKey = SvcKeyPrefix & LogosDeliveryServiceId

const
  AdvertFormatVersion* = 1'u8
    ## Bumped whenever the layout below changes, so a reader can refuse a
    ## payload it does not understand instead of misreading it.

  MaxAdvertLen* = 32
    ## Hard ceiling on the advertised payload. libp2p validates the `data` of a
    ## ServiceInfo and rejects anything larger, which is why this is a compact
    ## binary layout and not JSON: the JSON shape this replaced ran to ~188
    ## bytes and could never be advertised at all. For scale, the one service
    ## advertised successfully in production -- mix -- carries a 32-byte
    ## Curve25519 key and nothing else.

  AdvertHeaderLen = 4
  MaxShardBitmapLen* = MaxAdvertLen - AdvertHeaderLen
    ## 28 bytes, so shards 0..223 are representable. Higher indices are dropped
    ## rather than silently aliased onto a lower bit.

proc selfAdvertisementData*(conf: WakuConf, shards: seq[uint16]): seq[byte] =
  ## The payload published alongside the advertisement.
  ##
  ## Layout, little-endian bit order within each bitmap byte:
  ##
  ##   [0]      format version
  ##   [1..2]   cluster id, big-endian uint16
  ##   [3]      capabilities bitfield
  ##   [4..]    shard bitmap, one bit per shard, only as long as it needs to be
  ##
  ## Everything here is what a peer needs to decide whether to dial us: which
  ## network, what we serve, which shards we are on. `cluster` travels with
  ## `shards` because a shard index is meaningless without it. The node's
  ## version string used to be included and is not: it is the single largest
  ## field, it is not a selection criterion, and it does not fit the budget.
  ##
  ## Capabilities travel as the bitfield rather than as protocol id strings --
  ## the same information, four bytes instead of roughly a hundred.
  var payload = newSeq[byte](AdvertHeaderLen)
  payload[0] = AdvertFormatVersion
  payload[1] = byte(conf.clusterId shr 8)
  payload[2] = byte(conf.clusterId and 0xff)
  payload[3] = byte(conf.wakuFlags)

  for shard in shards:
    let idx = int(shard)
    let byteIdx = idx div 8
    if byteIdx >= MaxShardBitmapLen:
      warn "shard index too large to advertise",
        shard = shard, max = MaxShardBitmapLen * 8
      continue
    while payload.len <= AdvertHeaderLen + byteIdx:
      payload.add(0'u8)
    payload[AdvertHeaderLen + byteIdx] =
      payload[AdvertHeaderLen + byteIdx] or byte(1'u8 shl (idx mod 8))

  return payload

proc advertiseSelf*(
    discoveries: seq[IPeerDiscovery], conf: WakuConf, shards: seq[uint16]
): Future[void] {.async: (raises: []).} =
  ## Registers interest in `/logos/delivery` on every service-capable backend,
  ## and advertises this node there when it serves something. `shards` is what
  ## the node is actually subscribed to -- the caller resolves that, since the
  ## configured list is not the same thing under autosharding.
  ##
  ## Best-effort per backend: a node whose discovery could not announce it is
  ## degraded, not broken, and the other backends should still get their turn.
  let serves = conf.wakuFlags.isServiceNode()
  let data =
    if serves:
      selfAdvertisementData(conf, shards)
    else:
      @[]

  for discovery in discoveries:
    let info = (await discovery.backendInfo()).valueOr:
      debug "skipping backend with unreadable info", reason = error
      continue

    if SvcKind notin info.keyKinds:
      continue

    (await discovery.registerInterest(SvcKey)).isOkOr:
      warn "could not register interest in the delivery network",
        backend = info.id, reason = error

    if not serves:
      continue

    (await discovery.startAdvertising(SvcKey, data, @[])).isOkOr:
      warn "could not advertise this node on the delivery network",
        backend = info.id, reason = error
      continue

    info "advertising this node on the delivery network",
      backend = info.id, protocols = conf.wakuFlags.toCodecs()

proc advertiseMix*(
    discoveries: seq[IPeerDiscovery], conf: WakuConf
): Future[void] {.async: (raises: []).} =
  ## Advertises this node's mix public key, and registers interest in other mix
  ## nodes, on every service-capable backend.
  ##
  ## This goes through the interface rather than through
  ## `KademliaDiscoveryConf.servicesToAdvertise`, which is where it used to be
  ## injected at conf time. That reached only the in-process backend -- the conf
  ## object belongs to it, and the two kademlia hosts are mutually exclusive --
  ## so a node running mix with plugin-hosted discovery advertised nothing and
  ## found no mix peers. Same route as `advertiseSelf`, so both hosts get it.
  ##
  ## No signed record is passed, here or anywhere: every backend rejects one
  ## (`pre-signed advertisements not supported`) because libp2p builds and signs
  ## the advertisement from its own identity.
  if conf.mixConf.isNone():
    return

  let key = SvcKeyPrefix & MixProtocolID
  let data = @(conf.mixConf.get().mixPubKey)

  for discovery in discoveries:
    let info = (await discovery.backendInfo()).valueOr:
      debug "skipping backend with unreadable info", reason = error
      continue

    if SvcKind notin info.keyKinds:
      continue

    (await discovery.registerInterest(key)).isOkOr:
      warn "could not register interest in mix peers", backend = info.id, reason = error

    (await discovery.startAdvertising(key, data, @[])).isOkOr:
      warn "could not advertise this node as a mix node",
        backend = info.id, reason = error
      continue

    info "advertising this node as a mix node", backend = info.id
