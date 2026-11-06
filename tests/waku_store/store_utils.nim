{.used.}

import chronos, chronicles

import
  logos_delivery/waku/
    [node/peer_manager, waku_store, waku_store/client, libp2p_backend/host],
  ../testlib/[common, wakucore]

proc newTestWakuStore*(
    switch: Switch, handler: StoreQueryRequestHandler
): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuStore.new(peerManager, common.rng(), handler)

  Libp2pHost.new(switch).mountHandler(WakuStoreCodec, proto)

  return proto

proc newTestWakuStoreClient*(switch: Switch): WakuStoreClient {.gcsafe.} =
  let peerManager = PeerManager.new(switch)
  WakuStoreClient.new(peerManager, common.rng())
