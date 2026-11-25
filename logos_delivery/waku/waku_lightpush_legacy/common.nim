{.push raises: [].}

import results, chronos, libp2p/peerid
import ../waku_core

from ../waku_core/codecs import WakuLegacyLightPushCodec
export WakuLegacyLightPushCodec

type WakuLightPushResult*[T] = Result[T, string]

type PushMessageHandler* = proc(
  pubsubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[void]] {.async.}

type PushRequestHandler* = proc(
  peerId: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[void]] {.async.}
  ## Handles the push request of `peerId`, this node's own id for a request
  ## the node makes to itself.

const TooManyRequestsMessage* = "TOO_MANY_REQUESTS"
