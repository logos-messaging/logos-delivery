{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_core/topics/sharding,
  logos_delivery/waku/waku_lightpush,
  logos_delivery/waku/waku_lightpush/[client, common],
  logos_delivery/waku/common/rate_limit/setting,
  ../testlib/[common, wakucore]

proc newTestWakuLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    wakuAutoSharding = Sharding(clusterId: 1, shardCountGenZero: 8)
    proto = WakuLightPush.new(
      peerManager, rng, handler, some(wakuAutoSharding), rateLimitSetting
    )

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLightpushClient*(switch: Switch): WakuLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLightPushClient.new(peerManager, rng)
