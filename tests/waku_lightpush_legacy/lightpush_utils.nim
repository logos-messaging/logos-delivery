{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

logScope:
  topics = "test waku_lightpush_legacy"

import
  waku/node/peer_manager,
  waku/waku_lightpush_legacy,
  waku/waku_lightpush_legacy/[client, common],
  waku/common/rate_limit/setting,
  ../testlib/[common, wakucore]

proc newTestWakuLegacyLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): Future[WakuLegacyLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuLegacyLightPush.new(peerManager, rng, handler, rateLimitSetting)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLegacyLightpushClient*(switch: Switch): WakuLegacyLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLegacyLightPushClient.new(peerManager, rng)
