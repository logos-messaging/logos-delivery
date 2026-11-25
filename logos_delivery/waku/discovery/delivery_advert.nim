{.push raises: [].}

## The `/logos/delivery` advert as its reader sees it: the layout of the
## payload, and what a record must show before its peer counts as a mix node.
##
## A leaf module: `waku_kademlia` reads adverts and is imported by `waku_conf`,
## which `self_advertisement` (the writer) imports.

import std/base64
import results
import libp2p/crypto/curve25519
import libp2p_mix/mix_protocol
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/waku_enr/capabilities

const
  AdvertFormatVersion* = 1'u8
    ## Bumped whenever the layout changes, so a reader can refuse a payload it
    ## does not understand instead of misreading it.

  AdvertHeaderLen* = 4
    ## [0] format version, [1..2] cluster id, [3] capabilities bitfield. The
    ## shard bitmap follows. See `selfAdvertisementData`.

func advertisedCapabilities*(data: openArray[byte]): Opt[CapabilitiesBitfield] =
  ## The capabilities of a `/logos/delivery` payload, or none when it is not
  ## one this version reads.
  let raw =
    try:
      base64.decode(cast[string](@data))
    except ValueError:
      return Opt.none(CapabilitiesBitfield)
  if raw.len < AdvertHeaderLen or raw[0].byte != AdvertFormatVersion:
    return Opt.none(CapabilitiesBitfield)
  Opt.some(CapabilitiesBitfield(raw[3].byte))

func advertisedShards*(data: openArray[byte]): Opt[(uint16, seq[uint16])] =
  ## The cluster id and the shards of a `/logos/delivery` payload, or none
  ## when it is not one this version reads.
  let raw =
    try:
      base64.decode(cast[string](@data))
    except ValueError:
      return Opt.none((uint16, seq[uint16]))
  if raw.len < AdvertHeaderLen or raw[0].byte != AdvertFormatVersion:
    return Opt.none((uint16, seq[uint16]))
  let cluster = (uint16(raw[1].byte) shl 8) or uint16(raw[2].byte)
  var shards: seq[uint16]
  for byteIdx in AdvertHeaderLen ..< raw.len:
    for bit in 0 .. 7:
      if (raw[byteIdx].byte and byte(1'u8 shl bit)) != 0:
        shards.add(uint16((byteIdx - AdvertHeaderLen) * 8 + bit))
  Opt.some((cluster, shards))

func advertisedServing*(
    services: openArray[DiscoveredService], clusterId: Opt[uint16]
): (seq[string], seq[uint16]) =
  ## The protocol codecs and the shards the delivery payload of a record with
  ## these services claims, so that a peer known only from its record can be
  ## selected for a protocol and a shard without being connected first.
  ##
  ## A record of another cluster than `clusterId` claims nothing here: its
  ## shard indexes mean other shards, and the peer store keeps shards without
  ## their cluster. With no `clusterId` known, the record is taken as it is.
  for service in services:
    if service.id != LogosDeliveryServiceId:
      continue
    let caps = advertisedCapabilities(service.data).valueOr:
      continue
    let (cluster, shards) = advertisedShards(service.data).valueOr:
      continue
    if clusterId.isSome() and clusterId.get() != cluster:
      continue
    return (caps.toCodecs(), shards)
  (newSeq[string](), newSeq[uint16]())

func withoutMixClaim*(data: seq[byte]): seq[byte] =
  ## The `/logos/delivery` payload `data` with the Mix capability cleared.
  ## A payload this version does not read is returned as it is.
  var raw =
    try:
      base64.decode(cast[string](data))
    except ValueError:
      return data
  if raw.len < AdvertHeaderLen or raw[0].byte != AdvertFormatVersion:
    return data
  raw[3] = char(raw[3].byte and not byte(1'u8 shl ord(Capabilities.Mix)))
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
