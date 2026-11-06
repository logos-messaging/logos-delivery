## Relay on top of the built-in nim-libp2p GossipSub backend.
{.push raises: [].}

import results, libp2p/switch
import ../waku_core, ../waku_relay/[protocol, pubsub_params], ./gossipsub

export gossipsub

type WakuRelay* = WakuRelayOf[GossipSubBackend]

proc new*(
    T: type WakuRelay, switch: Switch, maxMessageSize = int(DefaultMaxWakuMessageSize)
): Result[WakuRelay, string] =
  let backend = GossipSubBackend.new(
    switch, WakuRelayCodec, WakuPubSubParams, maxMessageSize
  ).valueOr:
    return err(error)
  return WakuRelayOf[GossipSubBackend].new(backend, maxMessageSize)

proc mountOn*(
    relay: WakuRelay, switch: Switch, matcher: Matcher
) {.raises: [LPError].} =
  relay.pubsub.mountOn(switch, matcher)
