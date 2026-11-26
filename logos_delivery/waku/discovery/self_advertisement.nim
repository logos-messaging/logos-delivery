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

import std/[base64, sequtils]
import chronos, chronicles, results
import libp2p/crypto/curve25519
import libp2p_mix/mix_protocol
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/self_advert_brokers,
  logos_delivery/waku/discovery/delivery_advert,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/waku_enr/capabilities

export delivery_advert, self_advert_brokers

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
  ## mix key on the strength of it. `assembleAdvert` clears it for a record
  ## that lists no mix key.
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

type SelfAdvert* = object
  ## This node's record as it is advertised: the delivery payload, and the
  ## services listed in the same record.
  data*: Opt[seq[byte]] ## None for a node that serves nothing: it advertises nothing.
  secondary*: seq[DiscoveredService]

proc deliveryAdvertPart*(conf: WakuConf, shards: seq[uint16]): GetSelfAdvert =
  ## The record's own service. `shards` is what the node is actually subscribed
  ## to -- the caller resolves that, since the configured list is not the same
  ## thing under autosharding.
  GetSelfAdvert(
    service: DiscoveredService(
      id: LogosDeliveryServiceId, data: selfAdvertisementData(conf, shards)
    )
  )

func mixAdvertPart*(mixKey: Curve25519Key): GetSelfAdvert =
  ## This node's current mix key, as the `/mix/1.0.0` service of the record.
  GetSelfAdvert(service: DiscoveredService(id: MixProtocolID, data: @mixKey))

func assembleAdvert*(parts: openArray[GetSelfAdvert]): Result[SelfAdvert, string] =
  ## The record these parts make. The delivery part is the record: without it
  ## the node advertises nothing, whatever else is provided.
  ##
  ## A mix node lists its mix key in the same record, as the `/mix/1.0.0`
  ## service. Mix is not registered as a service of its own: a registrar makes
  ## a node wait for a second registration, and other nodes find mix nodes among
  ## the delivery nodes they look up anyway.
  ##
  ## The mix part is absent while the node cannot act as a mix node although it
  ## mounts mix: with Mix RLN, while it holds no usable Mix membership and so
  ## cannot prove a hop. The record then claims no Mix. A mix key is listed only
  ## in a record that claims Mix (`advertisesMix`).
  var advert = SelfAdvert()
  for part in parts:
    if part.service.id != LogosDeliveryServiceId:
      advert.secondary.add(part.service)
    elif advert.data.isSome():
      return err("more than one delivery part")
    else:
      advert.data = Opt.some(part.service.data)
  if advert.data.isNone():
    return ok(SelfAdvert())

  let claimsMix = advertisedCapabilities(advert.data.get())
    .get(CapabilitiesBitfield(0))
    .supportsCapability(Capabilities.Mix)
  var hasMixKey = false
  for service in advert.secondary:
    if service.id == MixProtocolID:
      hasMixKey = true
  if claimsMix and not hasMixKey:
    # Through a local: under refc the result of the call is built in
    # `advert.data`, which is emptied first, and that is the argument too.
    let payload = advert.data.get()
    advert.data = Opt.some(withoutMixClaim(payload))
  elif hasMixKey and not claimsMix:
    var kept: seq[DiscoveredService]
    for service in advert.secondary:
      if service.id != MixProtocolID:
        kept.add(service)
    advert.secondary = kept
  return ok(advert)

proc advertiseSelf*(
    discoveries: seq[IPeerDiscovery],
    advert: SelfAdvert,
    isCurrent: proc(): bool {.gcsafe, raises: [].} = nil,
): Future[void] {.async: (raises: []).} =
  ## Registers interest in `/logos/delivery` on every service-capable backend,
  ## and advertises `advert` there when the node serves something.
  ##
  ## Once `isCurrent` returns false (the record changed again, or the node is
  ## stopping), the advertisement stops after its current step, so a record that
  ## is no longer current is not published.
  ## See: https://lip.logos.co/anoncomms/raw/mix-key-rotation.html#4-key-publication
  ##
  ## Best-effort per backend: a node whose discovery could not announce it is
  ## degraded, not broken, and the other backends should still get their turn.
  template current(): bool =
    isCurrent.isNil() or isCurrent()

  let serves = advert.data.isSome()
  let data = advert.data.get(@[])
  let secondary = advert.secondary

  for discovery in discoveries:
    if not current():
      return
    let info = (await discovery.backendInfo()).valueOr:
      debug "skipping backend with unreadable info", reason = error
      continue

    if ServiceKind notin info.keyKinds:
      continue

    # The record can change while a step runs, and a cancelled step returns an
    # error, so each result is read only while the record is current.
    let registered = await discovery.registerInterest(SvcKey)
    if not current():
      return
    registered.isOkOr:
      warn "could not register interest in the delivery network",
        backend = info.id, reason = error

    if not serves:
      continue

    let advertised = await discovery.startAdvertising(SvcKey, data, secondary)
    if not current():
      return
    advertised.isOkOr:
      warn "could not advertise this node on the delivery network",
        backend = info.id, reason = error
      continue

    info "advertising this node on the delivery network",
      backend = info.id,
      protocols = advertisedCapabilities(data).get(CapabilitiesBitfield(0)).toCodecs(),
      listed = secondary.mapIt(it.id)

proc withdrawSelf*(discoveries: seq[IPeerDiscovery]) {.async: (raises: []).} =
  ## Stops advertising this node on every service-capable backend. A backend
  ## keeps the record it was given and publishes it again at the next start,
  ## when the mix key in it may be gone.
  for discovery in discoveries:
    let info = (await discovery.backendInfo()).valueOr:
      debug "skipping backend with unreadable info", reason = error
      continue
    if ServiceKind notin info.keyKinds:
      continue
    (await discovery.stopAdvertising(SvcKey)).isOkOr:
      warn "could not withdraw this node's advertisement",
        backend = info.id, reason = error
