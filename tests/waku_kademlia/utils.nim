{.used.}

import std/[options, sets]
import chronos, chronicles, results
import libp2p/[peerid, multiaddress, switch]
import libp2p/extended_peer_record
import libp2p/protocols/service_discovery/types as sd_types
import libp2p/crypto/crypto as libp2p_keys

import
  logos_delivery/waku/discovery/waku_kademlia,
  logos_delivery/waku/node/peer_manager/peer_manager
import ../testlib/[wakucore, common]

export wakucore, common, peerid, multiaddress, switch, extended_peer_record, sd_types

proc newTestKademlia*(
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    servicesToAdvertise: seq[ServiceInfo] = @[],
    servicesToDiscover: seq[string] = @[],
    randomLookupInterval: Duration = 100.milliseconds,
    serviceLookupInterval: Duration = 100.milliseconds,
    clientMode: bool = false,
    xprPublishing: bool = true,
): WakuKademlia =
  let peerManager = PeerManager.new(switch)

  let wk = WakuKademlia
    .new(
      switch = switch,
      peerManager = peerManager,
      bootstrapNodes = bootstrapNodes,
      servicesToAdvertise = toHashSet(servicesToAdvertise),
      servicesToDiscover = toHashSet(servicesToDiscover),
      randomLookupInterval = randomLookupInterval,
      serviceLookupInterval = serviceLookupInterval,
      rng = rng(),
      clientMode = clientMode,
      xprPublishing = xprPublishing,
    )
    .tryGet()

  switch.mount(wk.protocol)
  wk

proc buildExtendedPeerRecord*(
    peerId: PeerId, addrs: seq[MultiAddress], services: seq[ServiceInfo] = @[]
): ExtendedPeerRecord =
  ExtendedPeerRecord.init(peerId = peerId, addresses = addrs, services = services)
