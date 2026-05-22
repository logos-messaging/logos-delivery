when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, net, strformat],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  libp2p/crypto/crypto,
  confutils,
  libp2p/wire

import
  tools/confutils/cli_args,
  waku/[
    node/peer_manager,
    waku_lightpush/common,
    waku_relay,
    waku_filter_v2,
    waku_peer_exchange/protocol,
    waku_core/multiaddrstr,
    waku_enr/capabilities,
  ]
logScope:
  topics = "diagnose connections"

proc allPeers(pm: PeerManager): string =
  var allStr: string = ""
  for idx, peer in pm.switch.peerStore.peers():
    allStr.add(
      "    " & $idx & ". | " & constructMultiaddrStr(peer) & " | agent: " &
        peer.getAgent() & " | protos: " & $peer.protocols & " | caps: " &
        $peer.enr.map(getCapabilities) & "\n"
    )
  return allStr

proc logSelfPeers*(pm: PeerManager) =
  let selfLighpushPeers = pm.switch.peerStore.getPeersByProtocol(WakuLightPushCodec)
  let selfRelayPeers = pm.switch.peerStore.getPeersByProtocol(WakuRelayCodec)
  let selfFilterPeers = pm.switch.peerStore.getPeersByProtocol(WakuFilterSubscribeCodec)
  let selfPxPeers = pm.switch.peerStore.getPeersByProtocol(WakuPeerExchangeCodec)

  let printable = catch:
    """*------------------------------------------------------------------------------------------*
|  Self ({constructMultiaddrStr(pm.switch.peerInfo)}) peers:
*------------------------------------------------------------------------------------------*
|  Lightpush peers({selfLighpushPeers.len()}): ${selfLighpushPeers}
*------------------------------------------------------------------------------------------*
|  Filter peers({selfFilterPeers.len()}): ${selfFilterPeers}
*------------------------------------------------------------------------------------------*
|  Relay peers({selfRelayPeers.len()}): ${selfRelayPeers}
*------------------------------------------------------------------------------------------*
|  PX peers({selfPxPeers.len()}): ${selfPxPeers}
*------------------------------------------------------------------------------------------*
| All peers with protocol support:
{allPeers(pm)}
*------------------------------------------------------------------------------------------*""".fmt()

  echo printable.valueOr("Error while printing statistics: " & error.msg)
