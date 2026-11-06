{.used.}

import results, chronos, chronicles, libp2p/crypto/crypto

logScope:
  topics = "test waku_lightpush_legacy"

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_lightpush_legacy,
  logos_delivery/waku/waku_lightpush_legacy/[client, common],
  logos_delivery/waku/common/rate_limit/setting,
  logos_delivery/waku/libp2p_backend/host,
  ../testlib/[common, wakucore]

proc newTestWakuLegacyLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Opt[RateLimitSetting] = Opt.none(RateLimitSetting),
    maxMessageSize: int = int(DefaultMaxWakuMessageSize),
): Future[WakuLegacyLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuLegacyLightPush.new(
      peerManager, crypto.newRng(), handler, rateLimitSetting, maxMessageSize
    )

  Libp2pHost.new(switch).mountHandler(WakuLegacyLightPushCodec, proto)

  return proto

proc newTestWakuLegacyLightpushClient*(switch: Switch): WakuLegacyLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLegacyLightPushClient.new(peerManager, crypto.newRng())
