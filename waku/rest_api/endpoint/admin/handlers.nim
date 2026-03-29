{.push raises: [].}

import
  std/[sets, strformat, sequtils, tables],
  chronicles,
  chronicles/topics_registry,
  json_serialization,
  presto/route,
  libp2p/[peerinfo, switch, peerid, protocols/pubsub/pubsubpeer]

import
  waku/[
    waku_core,
    waku_core/topics/pubsub_topic,
    waku_store/common,
    waku_filter_v2,
    waku_lightpush_legacy/common,
    waku_relay,
    waku_peer_exchange,
    waku_node,
    node/peer_manager,
    waku_enr/sharding,
  ],
  ../responses,
  ../serdes,
  ../rest_serdes,
  ./types

export types

logScope:
  topics = "waku node rest admin api"

const ROUTE_ADMIN_V1_PEERS_STATS* = "/admin/v1/peers/stats" # provides peer statistics

const ROUTE_ADMIN_V1_PEERS* = "/admin/v1/peers" # returns all peers
const ROUTE_ADMIN_V1_SINGLE_PEER* = "/admin/v1/peer/{peerId}"

const ROUTE_ADMIN_V1_SERVICE_PEERS* = "/admin/v1/peers/service" # returns all peers

const ROUTE_ADMIN_V1_CONNECTED_PEERS* = "/admin/v1/peers/connected"
const ROUTE_ADMIN_V1_CONNECTED_PEERS_ON_SHARD* =
  "/admin/v1/peers/connected/on/{shardId}"
const ROUTE_ADMIN_V1_RELAY_PEERS* = "/admin/v1/peers/relay"
const ROUTE_ADMIN_V1_RELAY_PEERS_ON_SHARD* = "/admin/v1/peers/relay/on/{shardId}"
const ROUTE_ADMIN_V1_MESH_PEERS* = "/admin/v1/peers/mesh"
const ROUTE_ADMIN_V1_MESH_PEERS_ON_SHARD* = "/admin/v1/peers/mesh/on/{shardId}"

const ROUTE_ADMIN_V1_FILTER_SUBS* = "/admin/v1/filter/subscriptions"

const ROUTE_ADMIN_V1_POST_LOG_LEVEL* = "/admin/v1/log-level/{logLevel}"
  # sets the new log level for the node

type PeerProtocolTuple =
  tuple[
    multiaddr: string,
    protocol: string,
    shards: seq[uint16],
    connected: Connectedness,
    agent: string,
    origin: PeerOrigin,
  ]

proc tuplesToWakuPeers(peers: var WakuPeers, peersTup: seq[PeerProtocolTuple]) =
  for peer in peersTup:
    peers.add(
      peer.multiaddr, peer.protocol, peer.shards, peer.connected, peer.agent,
      peer.origin,
    )

proc populateAdminPeerInfo(
    peers: var WakuPeers, node: WakuNode, codec: Option[string] = none[string]()
) =
  if codec.isNone():
    peers = node.peerManager.switch.peerStore.peers().mapIt(WakuPeer.init(it))
  else:
    let peersTuples = node.peerManager.switch.peerStore.peers(codec.get()).mapIt(
        (
          multiaddr: constructMultiaddrStr(it),
          protocol: codec.get(),
          shards: it.getShards(),
          connected: it.connectedness,
          agent: it.agent,
          origin: it.origin,
        )
      )
    tuplesToWakuPeers(peers, peersTuples)

proc populateAdminPeerInfoForAll(node: WakuNode): WakuPeers =
  var peers: WakuPeers = @[]
  populateAdminPeerInfo(peers, node)
  return peers

proc populateAdminPeerInfoForCodecs(node: WakuNode, codecs: seq[string]): WakuPeers =
  var peers: WakuPeers = @[]

  for codec in codecs:
    populateAdminPeerInfo(peers, node, some(codec))

  return peers

proc getRelayPeers(node: WakuNode): PeersOfShards =
  var relayPeers: PeersOfShards = @[]
  if not node.wakuRelay.isNil():
    for topic in node.wakuRelay.getSubscribedTopics():
      let relayShard = RelayShard.parse(topic).valueOr:
        error "Invalid subscribed topic", error = error, topic = topic
        continue
      let pubsubPeers =
        node.wakuRelay.getConnectedPubSubPeers(topic).get(initHashSet[PubSubPeer](0))
      relayPeers.add(
        PeersOfShard(
          shard: relayShard.shardId,
          peers: toSeq(pubsubPeers).mapIt(WakuPeer.init(it, node.peerManager)),
        )
      )
  return relayPeers

proc getMeshPeers(node: WakuNode): PeersOfShards =
  var meshPeers: PeersOfShards = @[]
  if not node.wakuRelay.isNil():
    for topic in node.wakuRelay.getSubscribedTopics():
      let relayShard = RelayShard.parse(topic).valueOr:
        error "Invalid subscribed topic", error = error, topic = topic
        continue
      let peers =
        node.wakuRelay.getPubSubPeersInMesh(topic).get(initHashSet[PubSubPeer](0))
      meshPeers.add(
        PeersOfShard(
          shard: relayShard.shardId,
          peers: toSeq(peers).mapIt(WakuPeer.init(it, node.peerManager)),
        )
      )
  return meshPeers

proc installAdminV1GetPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_ADMIN_V1_PEERS) do() -> RestApiResponse:
    let peers = populateAdminPeerInfoForAll(node)

    let resp = RestApiResponse.jsonResponse(peers, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_SINGLE_PEER) do(
    peerId: string
  ) -> RestApiResponse:
    let peerIdString = peerId.valueOr:
      return RestApiResponse.badRequest("Invalid argument:" & $error)

    let peerIdVal: PeerId = PeerId.init(peerIdString).valueOr:
      return RestApiResponse.badRequest("Invalid argument:" & $error)

    if node.peerManager.switch.peerStore.peerExists(peerIdVal):
      let peerInfo = node.peerManager.switch.peerStore.getPeer(peerIdVal)
      let peer = WakuPeer.init(peerInfo)
      let resp = RestApiResponse.jsonResponse(peer, status = Http200).valueOr:
        error "An error occurred while building the json response: ", error = error
        return RestApiResponse.internalServerError(
          fmt("An error occurred while building the json response: {error}")
        )

      return resp
    else:
      return RestApiResponse.notFound(fmt("Peer with ID {peerId} not found"))

  router.api(MethodGet, ROUTE_ADMIN_V1_SERVICE_PEERS) do() -> RestApiResponse:
    let peers = populateAdminPeerInfoForCodecs(
      node,
      @[
        WakuRelayCodec, WakuFilterSubscribeCodec, WakuStoreCodec,
        WakuLegacyLightPushCodec, WakuLightPushCodec, WakuPeerExchangeCodec,
        WakuReconciliationCodec, WakuTransferCodec,
      ],
    )

    let resp = RestApiResponse.jsonResponse(peers, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_CONNECTED_PEERS) do() -> RestApiResponse:
    let allPeers = populateAdminPeerInfoForAll(node)

    let connectedPeers = allPeers.filterIt(it.connected == Connectedness.Connected)

    let resp = RestApiResponse.jsonResponse(connectedPeers, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_CONNECTED_PEERS_ON_SHARD) do(
    shardId: uint16
  ) -> RestApiResponse:
    let shard = shardId.valueOr:
      return RestApiResponse.badRequest(fmt("Invalid shardId: {error}"))

    let allPeers = populateAdminPeerInfoForAll(node)

    let connectedPeers = allPeers.filterIt(
      it.connected == Connectedness.Connected and it.shards.contains(shard)
    )

    let resp = RestApiResponse.jsonResponse(connectedPeers, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_RELAY_PEERS) do() -> RestApiResponse:
    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    var relayPeers: PeersOfShards = getRelayPeers(node)

    let resp = RestApiResponse.jsonResponse(relayPeers, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_RELAY_PEERS_ON_SHARD) do(
    shardId: uint16
  ) -> RestApiResponse:
    let shard = shardId.valueOr:
      return RestApiResponse.badRequest(fmt("Invalid shardId: {error}"))

    if node.wakuMetadata.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Metadata Protocol is not mounted to the node"
      )

    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    # TODO: clusterId and shards should be uint16 across all codebase and probably be defined as a type
    let topic = toPubsubTopic(
      RelayShard(clusterId: node.wakuMetadata.clusterId.uint16, shardId: shard)
    )
    let pubsubPeers =
      node.wakuRelay.getConnectedPubSubPeers(topic).get(initHashSet[PubSubPeer](0))
    let relayPeer = PeersOfShard(
      shard: shard, peers: toSeq(pubsubPeers).mapIt(WakuPeer.init(it, node.peerManager))
    )

    let resp = RestApiResponse.jsonResponse(relayPeer, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_MESH_PEERS) do() -> RestApiResponse:
    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    var meshPeers: PeersOfShards = getMeshPeers(node)

    let resp = RestApiResponse.jsonResponse(meshPeers, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_MESH_PEERS_ON_SHARD) do(
    shardId: uint16
  ) -> RestApiResponse:
    let shard = shardId.valueOr:
      return RestApiResponse.badRequest(fmt("Invalid shardId: {error}"))

    if node.wakuMetadata.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Metadata Protocol is not mounted to the node"
      )

    if node.wakuRelay.isNil():
      return RestApiResponse.serviceUnavailable(
        "Error: Relay Protocol is not mounted to the node"
      )

    let topic = toPubsubTopic(
      RelayShard(clusterId: node.wakuMetadata.clusterId.uint16, shardId: shard)
    )
    let peers =
      node.wakuRelay.getPubSubPeersInMesh(topic).get(initHashSet[PubSubPeer](0))
    let relayPeer = PeersOfShard(
      shard: shard, peers: toSeq(peers).mapIt(WakuPeer.init(it, node.peerManager))
    )

    let resp = RestApiResponse.jsonResponse(relayPeer, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

  router.api(MethodGet, ROUTE_ADMIN_V1_PEERS_STATS) do() -> RestApiResponse:
    let peers = populateAdminPeerInfoForAll(node)

    var stats: PeerStats = initOrderedTable[string, OrderedTable[string, int]]()

    stats["Sum"] = {"Total peers": peers.len()}.toOrderedTable()

    # stats of connectedness
    var connectednessStats = initOrderedTable[string, int]()
    connectednessStats[$Connectedness.Connected] =
      peers.countIt(it.connected == Connectedness.Connected)
    connectednessStats[$Connectedness.NotConnected] =
      peers.countIt(it.connected == Connectedness.NotConnected)
    connectednessStats[$Connectedness.CannotConnect] =
      peers.countIt(it.connected == Connectedness.CannotConnect)
    connectednessStats[$Connectedness.CanConnect] =
      peers.countIt(it.connected == Connectedness.CanConnect)
    stats["By Connectedness"] = connectednessStats

    # stats of relay peers
    var totalRelayPeers = 0
    stats["Relay peers"] = block:
      let relayPeers = getRelayPeers(node)
      var stat = initOrderedTable[string, int]()
      for ps in relayPeers:
        totalRelayPeers += ps.peers.len
        stat[$ps.shard] = ps.peers.len
      stat["Total relay peers"] = relayPeers.len
      stat

    # stats of mesh peers
    stats["Mesh peers"] = block:
      let meshPeers = getMeshPeers(node)
      var totalMeshPeers = 0
      var stat = initOrderedTable[string, int]()
      for ps in meshPeers:
        totalMeshPeers += ps.peers.len
        stat[$ps.shard] = ps.peers.len
      stat["Total mesh peers"] = meshPeers.len
      stat

    var protoStats = initOrderedTable[string, int]()
    protoStats[WakuRelayCodec] = peers.countIt(it.protocols.contains(WakuRelayCodec))
    protoStats[WakuFilterSubscribeCodec] =
      peers.countIt(it.protocols.contains(WakuFilterSubscribeCodec))
    protoStats[WakuFilterPushCodec] =
      peers.countIt(it.protocols.contains(WakuFilterPushCodec))
    protoStats[WakuStoreCodec] = peers.countIt(it.protocols.contains(WakuStoreCodec))
    protoStats[WakuLightPushCodec] =
      peers.countIt(it.protocols.contains(WakuLightPushCodec))
    protoStats[WakuLegacyLightPushCodec] =
      peers.countIt(it.protocols.contains(WakuLegacyLightPushCodec))
    protoStats[WakuPeerExchangeCodec] =
      peers.countIt(it.protocols.contains(WakuPeerExchangeCodec))
    protoStats[WakuReconciliationCodec] =
      peers.countIt(it.protocols.contains(WakuReconciliationCodec))

    stats["By Protocols"] = protoStats

    let resp = RestApiResponse.jsonResponse(stats, status = Http200).valueOr:
      error "An error occurred while building the json response: ", error = error
      return RestApiResponse.internalServerError(
        fmt("An error occurred while building the json response: {error}")
      )

    return resp

proc installAdminV1PostPeersHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodPost, ROUTE_ADMIN_V1_PEERS) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    let peers: seq[string] = decodeRequestBody[seq[string]](contentBody).valueOr:
      let e = $error
      return RestApiResponse.badRequest(fmt("Failed to decode request: {e}"))

    for i, peer in peers:
      let peerInfo = parsePeerInfo(peer).valueOr:
        let e = $error
        return RestApiResponse.badRequest(fmt("Couldn't parse remote peer info: {e}"))

      if not (await node.peerManager.connectPeer(peerInfo, source = "rest")):
        return RestApiResponse.badRequest(
          fmt("Failed to connect to peer at index: {i} - {peer}")
        )

    return RestApiResponse.ok()

proc installAdminV1GetFilterSubsHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_ADMIN_V1_FILTER_SUBS) do() -> RestApiResponse:
    if node.wakuFilter.isNil():
      return
        RestApiResponse.badRequest("Error: Filter Protocol is not mounted to the node")

    var
      subscriptions: seq[FilterSubscription] = @[]
      filterCriteria: seq[FilterTopic]

    for peerId in node.wakuFilter.subscriptions.peersSubscribed.keys:
      filterCriteria = node.wakuFilter.subscriptions.getPeerSubscriptions(peerId).mapIt(
          FilterTopic(pubsubTopic: it[0], contentTopic: it[1])
        )

      subscriptions.add(
        FilterSubscription(peerId: $peerId, filterCriteria: filterCriteria)
      )

    let resp = RestApiResponse.jsonResponse(subscriptions, status = Http200).valueOr:
      error "An error ocurred while building the json respose", error = error
      return RestApiResponse.internalServerError(
        fmt("An error ocurred while building the json respose: {error}")
      )

    return resp

proc installAdminV1PostLogLevelHandler(router: var RestRouter, node: WakuNode) =
  router.api(MethodPost, ROUTE_ADMIN_V1_POST_LOG_LEVEL) do(
    logLevel: string
  ) -> RestApiResponse:
    when runtimeFilteringEnabled:
      if logLevel.isErr() or logLevel.value().isEmptyOrWhitespace():
        return RestApiResponse.badRequest("Invalid log-level, it can’t be empty")

      try:
        let newLogLevel = parseEnum[LogLevel](logLevel.value().capitalizeAscii())

        if newLogLevel < enabledLogLevel:
          return RestApiResponse.badRequest(
            fmt(
              "Log level {newLogLevel} is lower than the lowest log level - {enabledLogLevel} - the binary is compiled with."
            )
          )

        setLogLevel(newLogLevel)
      except ValueError:
        return RestApiResponse.badRequest(
          fmt(
            "Invalid log-level: {logLevel.value()}. Please specify one of TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL"
          )
        )

      return RestApiResponse.ok()
    else:
      return RestApiResponse.serviceUnavailable(
        "Dynamic Log level management is not enabled in this build. Please recompile with `-d:chronicles_runtime_filtering:on`."
      )

proc installAdminApiHandlers*(router: var RestRouter, node: WakuNode) =
  installAdminV1GetPeersHandler(router, node)
  installAdminV1PostPeersHandler(router, node)
  installAdminV1GetFilterSubsHandler(router, node)
  installAdminV1PostLogLevelHandler(router, node)
