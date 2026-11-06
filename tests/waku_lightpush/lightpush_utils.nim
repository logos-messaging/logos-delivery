{.used.}

import results, chronos, chronicles, libp2p/crypto/crypto

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_core/topics/sharding,
  logos_delivery/waku/waku_lightpush,
  logos_delivery/waku/waku_lightpush/[client, common],
  logos_delivery/waku/common/rate_limit/setting,
  logos_delivery/waku/libp2p_backend/host,
  ../testlib/[common, wakucore]

proc newTestWakuLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Opt[RateLimitSetting] = Opt.none(RateLimitSetting),
    maxMessageSize: int = int(DefaultMaxWakuMessageSize),
): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    wakuAutoSharding = Sharding(clusterId: 1, shardCountGenZero: 8)
    proto = WakuLightPush.new(
      peerManager,
      crypto.newRng(),
      handler,
      Opt.some(wakuAutoSharding),
      rateLimitSetting,
      maxMessageSize,
    )

  Libp2pHost.new(switch).mountHandler(WakuLightPushCodec, proto)

  return proto

proc newTestWakuLightpushClient*(switch: Switch): WakuLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLightPushClient.new(peerManager, crypto.newRng())
