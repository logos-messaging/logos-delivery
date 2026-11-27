{.push raises: [].}

## The `/logos/delivery` advert as its reader sees it: the layout of the
## payload, and what a record must show before its peer counts as a mix node.
##
## A leaf module: `waku_kademlia` reads adverts and is imported by `waku_conf`,
## which `self_advertisement` (the writer) imports.

import std/base64
import results, chronicles, stew/[bitops2, endians2]
import libp2p/crypto/curve25519
import libp2p_mix/mix_protocol
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/waku_enr/capabilities

const
  AdvertFormatVersion* = 2'u8
    ## Bumped whenever the layout changes, so a reader can refuse a payload it
    ## does not understand instead of misreading it.

  AdvertHeaderLen* = 5
    ## [0] format version, [1..2] cluster id, [3..4] capabilities bitfield. The
    ## shard bitmap follows. See `selfAdvertisementData`.

func decodedAdvert(data: openArray[byte]): Result[seq[byte], string] =
  ## The raw bytes of a `/logos/delivery` payload this version reads, in the
  ## layout of version 2.
  let raw =
    try:
      cast[seq[byte]](base64.decode(cast[string](@data)))
    except ValueError as exc:
      return err("delivery advert is not base64: " & exc.msg)
  # Version 1 has one byte of capabilities.
  # v0.39.0 is the first release that writes it.
  let advert =
    if raw.len >= 4 and raw[0] == 1'u8:
      @[2'u8] & raw[1 .. 2] & @[0'u8] & raw[3 .. ^1]
    else:
      raw
  if advert.len < AdvertHeaderLen:
    return err("delivery advert shorter than its header: " & $raw.len)
  if advert[0] != AdvertFormatVersion:
    return err("unsupported delivery advert version: " & $advert[0])
  ok(advert)

func advertisedCapabilities*(
    data: openArray[byte]
): Result[CapabilitiesBitfield, string] =
  ## The capabilities of a `/logos/delivery` payload.
  let raw = decodedAdvert(data).valueOr:
    return err("could not read delivery advert capabilities: " & error)
  ok(CapabilitiesBitfield(raw[4]))

func advertisedShards*(data: openArray[byte]): Result[(uint16, seq[uint16]), string] =
  ## The cluster id and the shards of a `/logos/delivery` payload. Bit `i` of
  ## the bitmap, least significant bit first, is shard `i`.
  let raw = decodedAdvert(data).valueOr:
    return err("could not read delivery advert shards: " & error)
  let cluster = uint16.fromBytesBE(raw.toOpenArray(1, 2))
  var shards: seq[uint16]
  for shard in 0 ..< (raw.len - AdvertHeaderLen) * 8:
    if raw.getBit(AdvertHeaderLen * 8 + shard):
      shards.add(uint16(shard))
  ok((cluster, shards))

proc advertisedServing*(
    services: openArray[DiscoveredService], ownClusterId: uint16
): (seq[string], seq[uint16]) =
  ## The protocol codecs and the shards the delivery payload of a record with
  ## these services claims, so that a peer known only from its record can be
  ## selected for a protocol and a shard without being connected first.
  ##
  ## A record of another cluster than this node's (`ownClusterId`) claims
  ## nothing here: its shard indexes mean other shards, and the peer store
  ## keeps shards without their cluster.
  for service in services:
    if service.id != LogosDeliveryServiceId:
      continue
    let caps = advertisedCapabilities(service.data).valueOr:
      debug "Delivery record claims nothing", reason = error
      continue
    let (cluster, shards) = advertisedShards(service.data).valueOr:
      debug "Delivery record claims nothing", reason = error
      continue
    if cluster != ownClusterId:
      trace "Delivery record of another cluster claims nothing",
        cluster = cluster, ownClusterId = ownClusterId
      continue
    return (caps.toCodecs(), shards)
  (newSeq[string](), newSeq[uint16]())

func withoutMixClaim*(data: seq[byte]): seq[byte] =
  ## The `/logos/delivery` payload `data` with the Mix capability cleared.
  ## A payload this version does not read is returned as it is.
  var raw = decodedAdvert(data).valueOr:
    return data
  raw[4] = raw[4] and not byte(1'u8 shl ord(Capabilities.Mix))
  cast[seq[byte]](base64.encode(raw))

func advertisedMixKey*(services: openArray[DiscoveredService]): Opt[Curve25519Key] =
  ## The mix key of a peer whose record lists these services.
  ##
  ## A mix node is a delivery node with relay mounted. Its record is the
  ## delivery record: the payload claims Relay and Mix, and a `/mix/1.0.0`
  ## entry carries the key. A key without that claim is not taken, so the pool
  ## holds no node that does not say it relays for the network.
  var
    claimed = false
    key = Opt.none(Curve25519Key)
  for service in services:
    if service.id == LogosDeliveryServiceId:
      let caps = advertisedCapabilities(service.data).valueOr:
        continue
      claimed =
        caps.supportsCapability(Capabilities.Relay) and
        caps.supportsCapability(Capabilities.Mix)
    elif key.isNone() and service.id == MixProtocolID and
        service.data.len == Curve25519KeySize:
      key = Opt.some(intoCurve25519Key(service.data))
  if not claimed:
    return Opt.none(Curve25519Key)
  key

func disclaimsMix*(services: openArray[DiscoveredService]): bool =
  ## Whether a record listing these services says that its peer is no mix
  ## node: its delivery payload is one this version reads and claims not both
  ## Relay and Mix. Only such a record removes a mix key stored before.
  ##
  ## A record without a delivery payload, or with one this version cannot read,
  ## says nothing. Nor does a payload that claims Mix but comes without a key:
  ## the record libp2p publishes under a node's own peer id, which a random
  ## lookup returns, lists the delivery service with its payload but not the
  ## `/mix/1.0.0` entry of the record the node signs for its advert.
  var disclaimed = false
  for service in services:
    if service.id == LogosDeliveryServiceId:
      let caps = advertisedCapabilities(service.data).valueOr:
        continue
      disclaimed = not (
        caps.supportsCapability(Capabilities.Relay) and
        caps.supportsCapability(Capabilities.Mix)
      )
  disclaimed
