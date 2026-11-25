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
