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
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/waku_enr/capabilities,
  logos_delivery/waku/waku_mix

logScope:
  topics = "waku discovery advertise"

const SvcKey = ServiceKeyPrefix & LogosDeliveryServiceId

const
  AdvertFormatVersion* = 1'u8
    ## Bumped whenever the layout below changes, so a reader can refuse a
    ## payload it does not understand instead of misreading it.

  MaxAdvertLen* = 32
    ## Hard ceiling on the advertised payload: libp2p validates the `data` of a
    ## ServiceInfo and rejects anything larger. The JSON shape this replaced ran
    ## to ~188 bytes and could never be advertised at all. For scale, the one
    ## service advertised successfully in production -- mix -- carries a 32-byte
    ## Curve25519 key and nothing else.

  MaxRawLen = 24 ## Base64 of 24 bytes is exactly 32 characters, unpadded.

  AdvertHeaderLen = 4
  MaxShardBitmapLen* = MaxRawLen - AdvertHeaderLen
    ## 20 bytes, so shards 0..159 are representable. Higher indices are dropped
    ## rather than silently aliased onto a lower bit, which would advertise
    ## membership of a shard we are not on.

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

type ServiceBackend = tuple[discovery: IPeerDiscovery, id: string]

proc serviceBackends(
    discoveries: seq[IPeerDiscovery]
): Future[seq[ServiceBackend]] {.async: (raises: []).} =
  ## Returns the backends that accept service keys, with their ids. Put the
  ## result in a `let` before a loop that awaits. A `for` over the `await` keeps
  ## a pointer into the future, and the GC can free it at the next `await`.
  var backends: seq[ServiceBackend]
  for discovery in discoveries:
    let info = (await discovery.backendInfo()).valueOr:
      debug "Skipping backend with unreadable info", reason = error
      continue
    if ServiceKind in info.keyKinds:
      backends.add((discovery, info.id))
  return backends

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

    if ServiceKind notin info.keyKinds:
      continue

    (await discovery.registerInterest(SvcKey)).isOkOr:
      warn "could not register interest in the delivery network",
        backend = info.id, reason = error

    if not serves:
      continue

    (await discovery.startAdvertising(SvcKey, data)).isOkOr:
      warn "could not advertise this node on the delivery network",
        backend = info.id, reason = error
      continue

    info "advertising this node on the delivery network",
      backend = info.id, protocols = conf.wakuFlags.toCodecs()

func canAdvertiseMix*(
    conf: WakuConf, selfHopAllowed: bool, selfHopSource: SelfHopSource
): Result[void, string] =
  ## Returns ok when this node can advertise itself as a mix node, else the
  ## reason. An `Observed` host can be a NAT gateway with no port forward to this
  ## node.
  if conf.mixConf.isNone():
    return err("mix is not mounted")
  if not conf.wakuFlags.isServiceNode():
    return err("a client-only node sends over mix but does not forward for others")
  if not selfHopAllowed:
    return err("the address policy does not accept the self hop")
  if selfHopSource == SelfHopSource.Observed:
    return err(
      "only other peers observed the address of the self hop. If peers can dial " &
        "this node at that address, set --nat=extip:<IP>, --ext-multiaddr, " &
        "--dns4-domain-name or a public listen address"
    )
  return ok()

proc writeMixAdvertisement(
    discoveries: seq[IPeerDiscovery], conf: WakuConf, advertise: bool
): Future[void] {.async: (raises: []).} =
  ## Starts or stops the mix advertisement on each backend.
  let key = ServiceKeyPrefix & MixProtocolID
  let data = @(conf.mixConf.get().mixPubKey)
  let backends = await serviceBackends(discoveries)
  for (discovery, id) in backends:
    if advertise:
      (await discovery.startAdvertising(key, data)).isOkOr:
        warn "could not advertise this node as a mix node", backend = id, reason = error
        continue
      debug "advertising this node as a mix node", backend = id
    else:
      (await discovery.stopAdvertising(key)).isOkOr:
        warn "could not stop advertising this node as a mix node",
          backend = id, reason = error

proc updateMixAdvertisement*(
    discoveries: seq[IPeerDiscovery],
    conf: WakuConf,
    mix: WakuMix,
    selfHopSource: SelfHopSource,
): Future[void] {.async: (raises: []).} =
  ## Starts or stops the mix advertisement when the result of `canAdvertiseMix`
  ## changes. Call it when the self hop changes.
  if mix.isNil() or conf.mixConf.isNone():
    return
  let allowed = canAdvertiseMix(conf, mix.selfHopAllowed(), selfHopSource)
  # Only a service node logs a new reason not to advertise.
  if allowed.isErr() and allowed.error != mix.notAdvertisingReason and
      conf.wakuFlags.isServiceNode():
    mix.notAdvertisingReason = allowed.error
    if not mix.advertised:
      info "not advertising this node as a mix node", reason = allowed.error
  if allowed.isOk():
    mix.notAdvertisingReason = ""
  if allowed.isOk() == mix.advertised:
    return
  mix.advertised = allowed.isOk()
  if allowed.isOk():
    info "starting the mix advertisement of this node"
  else:
    info "stopping the mix advertisement of this node", reason = allowed.error
  await writeMixAdvertisement(discoveries, conf, mix.advertised)

proc advertiseMix*(
    discoveries: seq[IPeerDiscovery],
    conf: WakuConf,
    mix: WakuMix,
    selfHopSource: SelfHopSource,
): Future[void] {.async: (raises: []).} =
  ## Registers interest in mix nodes on each backend, then advertises this node
  ## as a mix node when `canAdvertiseMix` allows it.
  ##
  ## This goes through the interface rather than through
  ## `KademliaDiscoveryConf.servicesToAdvertise`, which is where it used to be
  ## injected at conf time. That reached only the in-process backend -- the conf
  ## object belongs to it, and the two kademlia hosts are mutually exclusive --
  ## so a node running mix with plugin-hosted discovery advertised nothing and
  ## found no mix peers. Same route as `advertiseSelf`, so both hosts get it.
  ##
  ## Only the service id and the key bytes travel: whether a record is signed
  ## here or by libp2p is each backend's business (see `startAdvertising` on
  ## the interface).
  if conf.mixConf.isNone():
    return

  let key = ServiceKeyPrefix & MixProtocolID
  let backends = await serviceBackends(discoveries)
  for (discovery, id) in backends:
    (await discovery.registerInterest(key)).isOkOr:
      warn "could not register interest in mix peers", backend = id, reason = error

  await updateMixAdvertisement(discoveries, conf, mix, selfHopSource)
