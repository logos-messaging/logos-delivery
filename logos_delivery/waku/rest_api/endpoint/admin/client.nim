{.push raises: [].}

import chronicles, json_serialization, presto/[route, client], stew/byteutils

import ../serdes, ../rest_serdes, ./types

export types

logScope:
  topics = "waku node rest admin api"

proc encodeBytes*(value: seq[string], contentType: string): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc getPeers*(): RestResponse[seq[WakuPeer]] {.
  rest, endpoint: "/admin/v1/peers", meth: HttpMethod.MethodGet
.}

proc postPeers*(
  body: seq[string]
): RestResponse[string] {.
  rest, endpoint: "/admin/v1/peers", meth: HttpMethod.MethodPost
.}

proc getPeerById*(
  peerId: string
): RestResponse[WakuPeer] {.
  rest, endpoint: "/admin/v1/peer/{peerId}", meth: HttpMethod.MethodGet
.}

proc getServicePeers*(): RestResponse[seq[WakuPeer]] {.
  rest, endpoint: "/admin/v1/peers/service", meth: HttpMethod.MethodGet
.}

proc getConnectedPeers*(): RestResponse[seq[WakuPeer]] {.
  rest, endpoint: "/admin/v1/peers/connected", meth: HttpMethod.MethodGet
.}

proc getConnectedPeersByShard*(
  shardId: uint16
): RestResponse[seq[WakuPeer]] {.
  rest, endpoint: "/admin/v1/peers/connected/on/{shardId}", meth: HttpMethod.MethodGet
.}

proc getRelayPeers*(): RestResponse[PeersOfShards] {.
  rest, endpoint: "/admin/v1/peers/relay", meth: HttpMethod.MethodGet
.}

proc getRelayPeersByShard*(
  shardId: uint16
): RestResponse[PeersOfShard] {.
  rest, endpoint: "/admin/v1/peers/relay/on/{shardId}", meth: HttpMethod.MethodGet
.}

proc getMeshPeers*(): RestResponse[PeersOfShards] {.
  rest, endpoint: "/admin/v1/peers/mesh", meth: HttpMethod.MethodGet
.}

proc getMeshPeersByShard*(
  shardId: uint16
): RestResponse[PeersOfShard] {.
  rest, endpoint: "/admin/v1/peers/mesh/on/{shardId}", meth: HttpMethod.MethodGet
.}

proc getPeersStats*(): RestResponse[PeerStats] {.
  rest, endpoint: "/admin/v1/peers/stats", meth: HttpMethod.MethodGet
.}

proc getFilterSubscriptions*(): RestResponse[seq[FilterSubscription]] {.
  rest, endpoint: "/admin/v1/filter/subscriptions", meth: HttpMethod.MethodGet
.}

proc getFilterSubscriptionsFilterNotMounted*(): RestResponse[string] {.
  rest, endpoint: "/admin/v1/filter/subscriptions", meth: HttpMethod.MethodGet
.}
