{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import
  waku/node/peer_manager,
  waku/waku_core,
  waku/waku_core/topics/sharding,
  waku/waku_lightpush,
  waku/waku_lightpush/[client, common],
  waku/common/rate_limit/setting,
  ../testlib/[common, wakucore]

proc newTestWakuLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    wakuAutoSharding = Sharding.init(clusterId = 1, shardCount = 8)
    proto = WakuLightPush.new(
      peerManager, rng, handler, some(wakuAutoSharding), rateLimitSetting
    )

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLightpushClient*(switch: Switch): WakuLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLightPushClient.new(peerManager, rng)
