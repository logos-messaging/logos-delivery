{.used.}

import std/options, chronos, chronicles

import
  logos_delivery/waku/[node/peer_manager, waku_store, waku_store/client],
  ../testlib/[common, wakucore]

proc newTestWakuStore*(
    switch: Switch, handler: StoreQueryRequestHandler
): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuStore.new(peerManager, rng, handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStoreClient*(switch: Switch): WakuStoreClient {.gcsafe.} =
  let peerManager = PeerManager.new(switch)
  WakuStoreClient.new(peerManager, rng)
