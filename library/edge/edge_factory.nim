## Slim edge factory: builds only what a browser edge node needs — a libp2p
## Switch over the browser-WebSocket transport (noise + muxers), a PeerManager,
## a WakuNode, and the lightpush + filter clients. Deliberately avoids the full
## `factory/waku.nim` (relay / store / rln / discv5 / archive), none of which
## compile or belong in a browser edge node.

{.push raises: [].}

import chronos, results
# Standalone, QUIC/autotls/wstransport-free copy of libp2p's SwitchBuilder so a
# browser edge build never pulls lsquic/boringssl (unbuildable for wasm). See
# wasm-deps/edge_builders.nim. Bypasses libp2p/builders entirely (which Nim
# resolves to the real package regardless of --path overrides). Quoted because
# the hyphen in the path would otherwise parse as a minus.
import "../../wasm-deps/edge_builders"
import
  libp2p/switch,
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  libp2p/transports/transport,
  libp2p/upgrademngrs/upgrade
import ./ws_browser_transport
import ./edge_name_resolver

proc newEdgeSwitch*(
    rng: ref HmacDrbgContext, privKey: crypto.PrivateKey
): Switch {.raises: [LPError].} =
  ## A dial-only switch: browser-WebSocket transport + noise + yamux/mplex.
  ## No listen transport (TCP can't run in a browser); the edge node only dials.
  let sw = SwitchBuilder
  .new()
  .withRng(rng)
  .withPrivateKey(privKey)
  .withAddress(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get())
  .withTransport(
    proc(upgr: Upgrade, privateKey: crypto.PrivateKey): Transport =
      WsBrowserTransport.new(upgr)
  )
  .withYamux()
  .withMplex()
  .withNoise()
  .withNameResolver(EdgeNameResolver())
  .build()
  sw
