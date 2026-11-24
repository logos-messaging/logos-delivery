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
## them: a backend receives this only if its `keyKinds` includes `service`. That is
## true of both kademlia hosts -- in-process and plugin -- and false of discv5,
## whose advertising means mutating our own ENR and which rejects `service:` keys
## outright.

import std/base64
import chronos, chronicles, results
import libp2p_mix/mix_protocol
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/delivery_advert,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/waku_enr/capabilities

export delivery_advert

logScope:
  topics = "waku discovery advertise"

const SvcKey = ServiceKeyPrefix & LogosDeliveryServiceId

const
  MaxAdvertLen* = 32
    ## Hard ceiling on the advertised payload: libp2p validates the `data` of a
    ## ServiceInfo and rejects anything larger. The JSON shape this replaced ran
    ## to ~188 bytes and could never be advertised at all. For scale, the one
    ## service advertised successfully in production -- mix -- carries a 32-byte
    ## Curve25519 key and nothing else.

  MaxRawLen = 24 ## Base64 of 24 bytes is exactly 32 characters, unpadded.

  MaxShardBitmapLen* = MaxRawLen - AdvertHeaderLen
    ## 20 bytes, so shards 0..159 are representable. Higher indices are dropped
    ## rather than silently aliased onto a lower bit, which would advertise
    ## membership of a shard we are not on.

func advertisesMix*(conf: WakuConf): bool =
  ## A node advertises its mix key only when it mounts mix and relay. Relay is
  ## what Core mode means down here, where the configuration has no mode: an
  ## edge node mounts mix to send through it and is no hop for others.
  conf.mixConf.isSome() and conf.wakuFlags.supportsCapability(Capabilities.Relay)

proc selfAdvertisementData*(conf: WakuConf, shards: seq[uint16]): seq[byte] =
  ## The payload published alongside the advertisement: base64 of a compact
  ## binary record, at most `MaxAdvertLen` bytes on the wire.
  ##
  ## Layout before encoding, little-endian bit order within each bitmap byte:
  ##
  ##   [0]      format version
  ##   [1..2]   cluster id, big-endian uint16
  ##   [3]      capabilities bitfield
  ##   [4..]    shard bitmap, one bit per shard, only as long as it needs to be
  ##
  ## Everything a peer needs in order to decide whether to dial us: which
  ## network, what we serve, which shards we are on. `cluster` travels with
  ## `shards` because a shard index is meaningless without it. Capabilities
  ## travel as the bitfield rather than as protocol id strings -- the same
  ## information, one byte instead of roughly a hundred. The node's version
  ## string used to be included and is not: it is the single largest field, it
  ## is not a selection criterion, and it does not fit the budget.
  ##
  ## The Mix bit is set only when `advertisesMix`: a reader takes this node's
  ## mix key on the strength of it.
  ##
  ## Base64 rather than the raw bytes, even though the plugin ABI carries
  ## `data` as a length-counted byte array and the in-process backend would
  ## take binary happily. The plugin-hosted path reaches its provider over
  ## logos-core, whose generated client marshals arguments as JSON strings, and
  ## a JSON string must be valid UTF-8 -- a raw record throws
  ## `type_error.316` there and takes the hosting module down with it.
  ## The two hosts must publish byte-identical payloads to be able to find each
  ## other, so the encoding belongs here, once, rather than on one path only.
  var raw = newSeq[byte](AdvertHeaderLen)
  raw[0] = AdvertFormatVersion
  raw[1] = byte(conf.clusterId shr 8)
  raw[2] = byte(conf.clusterId and 0xff)
  raw[3] = byte(conf.wakuFlags)
  if not conf.advertisesMix():
    raw[3] = raw[3] and not byte(1'u8 shl ord(Capabilities.Mix))

  for shard in shards:
    let idx = int(shard)
    let byteIdx = idx div 8
    if byteIdx >= MaxShardBitmapLen:
      warn "shard index too large to advertise",
        shard = shard, max = MaxShardBitmapLen * 8
      continue
    while raw.len <= AdvertHeaderLen + byteIdx:
      raw.add(0'u8)
    raw[AdvertHeaderLen + byteIdx] =
      raw[AdvertHeaderLen + byteIdx] or byte(1'u8 shl (idx mod 8))

  return cast[seq[byte]](base64.encode(raw))

proc advertiseSelf*(
    discoveries: seq[IPeerDiscovery], conf: WakuConf, shards: seq[uint16]
): Future[void] {.async: (raises: []).} =
  ## Registers interest in `/logos/delivery` on every service-capable backend,
  ## and advertises this node there when it serves something. `shards` is what
  ## the node is actually subscribed to -- the caller resolves that, since the
  ## configured list is not the same thing under autosharding.
  ##
  ## A mix node (`advertisesMix`) lists its mix key in the same record, as the
  ## `/mix/1.0.0` service. Mix is not registered as a service of its own: a
  ## registrar makes a node wait for a second registration, and other nodes
  ## find mix nodes among the delivery nodes they look up anyway.
  ##
  ## Best-effort per backend: a node whose discovery could not announce it is
  ## degraded, not broken, and the other backends should still get their turn.
  let serves = conf.wakuFlags.isServiceNode()
  let data =
    if serves:
      selfAdvertisementData(conf, shards)
    else:
      @[]
  let secondary =
    if conf.advertisesMix():
      @[DiscoveredService(id: MixProtocolID, data: @(conf.mixConf.get().mixPubKey))]
    else:
      @[]

  for discovery in discoveries:
    let info = (await discovery.backendInfo()).valueOr:
      debug "skipping backend with unreadable info", reason = error
      continue

    if ServiceKind notin info.keyKinds:
      continue

    (await discovery.registerInterest(SvcKey)).isOkOr:
      warn "could not register interest in the delivery network",
        backend = info.id, reason = error

    if not serves:
      continue

    (await discovery.startAdvertising(SvcKey, data, secondary)).isOkOr:
      warn "could not advertise this node on the delivery network",
        backend = info.id, reason = error
      continue

    info "advertising this node on the delivery network",
      backend = info.id,
      protocols = conf.wakuFlags.toCodecs(),
      mixNode = secondary.len > 0
