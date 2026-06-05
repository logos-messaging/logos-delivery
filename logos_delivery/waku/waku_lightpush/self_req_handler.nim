{.push raises: [].}

## Notice that the REST /lightpush requests normally assume that the node
## is acting as a lightpush-client that will trigger the service provider node
## to relay the message.
## In this module, we allow that a lightpush service node (full node) can be
## triggered directly through the  REST /lightpush endpoint.
## The typical use case for that is when using `nwaku-compose`,
## which spawn a full service Waku node
## that could be used also as a lightpush client, helping testing and development.

import results, chronos, std/options, metrics
import ../waku_core, ./protocol, ./common, ./rpc, ./rpc_codec, ../utils/requests

proc handleSelfLightPushRequest*(
    self: WakuLightPush, pubSubTopic: Option[PubsubTopic], message: WakuMessage
): Future[WakuLightPushResult] {.async.} =
  ## Handles the lightpush requests made by the node to itself.
  ## Normally used in REST-lightpush requests
  ## On success, returns the msg_hash of the published message.

  try:
    # provide self peerId as now this node is used directly, thus there is no light client sender peer.
    let selfPeerId = self.peerManager.switch.peerInfo.peerId

    let req = LightpushRequest(
      requestId: generateRequestId(self.rng), pubSubTopic: pubSubTopic, message: message
    )

    let response = await self.handleRequest(selfPeerId, req.encode().buffer)

    return response.toPushResult()
  except Exception:
    return lightPushResultInternalError(
      "exception in handleSelfLightPushRequest: " & getCurrentExceptionMsg()
    )
