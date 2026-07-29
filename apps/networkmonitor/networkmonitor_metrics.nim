{.push raises: [].}

import
  std/[net, json, tables, sequtils],
  chronicles,
  chronicles/topics_registry,
  chronos,
  json_serialization,
  metrics,
  metrics/chronos_httpserver,
  presto/route,
  presto/server,
  results

logScope:
  topics = "networkmonitor_metrics"

# On top of our custom metrics, the following are reused from nim-eth
#routing_table_nodes{state=""}
#routing_table_nodes{state="seen"}
#discovery_message_requests_outgoing_total{response=""}
#discovery_message_requests_outgoing_total{response="no_response"}

declarePublicGauge logos_delivery_networkmonitor_peer_type_as_per_enr,
  "Number of peers supporting each capability according to the ENR",
  labels = ["capability"]

declarePublicGauge logos_delivery_networkmonitor_peer_cluster_as_per_enr,
  "Number of peers on each cluster according to the ENR", labels = ["cluster"]

declarePublicGauge logos_delivery_networkmonitor_peer_type_as_per_protocol,
  "Number of peers supporting each protocol, after a successful connection) ",
  labels = ["protocols"]

declarePublicGauge logos_delivery_networkmonitor_peer_user_agents,
  "Number of peers with each user agent", labels = ["user_agent"]

declarePublicHistogram logos_delivery_networkmonitor_peer_ping,
  "Histogram tracking ping durations for discovered peers",
  buckets = [10.0, 20.0, 50.0, 100.0, 200.0, 300.0, 500.0, 800.0, 1000.0, 2000.0, Inf]

declarePublicGauge logos_delivery_networkmonitor_peer_count,
  "Number of discovered peers", labels = ["connected"]

declarePublicGauge logos_delivery_networkmonitor_peer_country_count,
  "Number of peers per country", labels = ["country"]

type
  CustomPeerInfo* = object # populated after discovery
    lastTimeDiscovered*: int64
    discovered*: int64
    peerId*: string
    enr*: string
    ip*: string
    enrCapabilities*: seq[string]
    country*: string
    city*: string
    maddrs*: seq[string]

    # only after ok connection
    lastTimeConnected*: int64
    retries*: int64
    supportedProtocols*: seq[string]
    userAgent*: string
    lastPingDuration*: Duration
    avgPingDuration*: Duration

    # only after a ok/nok connection
    connError*: string

  CustomPeerInfoRef* = ref CustomPeerInfo

  # Stores information about all discovered/connected peers
  CustomPeersTableRef* = TableRef[string, CustomPeerInfoRef]

  # stores the content topic and the count of rx messages
  ContentTopicMessageTableRef* = TableRef[string, int]

proc installHandler*(
    router: var RestRouter,
    allPeers: CustomPeersTableRef,
    numMessagesPerContentTopic: ContentTopicMessageTableRef,
) =
  router.api(MethodGet, "/allpeersinfo") do() -> RestApiResponse:
    let values = toSeq(allPeers.values())
    return RestApiResponse.response(values.toJson(), contentType = "application/json")
  router.api(MethodGet, "/contenttopics") do() -> RestApiResponse:
    # TODO: toJson() includes the hash
    return RestApiResponse.response(
      $(%numMessagesPerContentTopic), contentType = "application/json"
    )

proc startMetricsServer*(serverIp: IpAddress, serverPort: Port): Result[void, string] =
  info "Starting metrics HTTP server", serverIp, serverPort

  try:
    startMetricsHttpServer($serverIp, serverPort)
  except Exception as e:
    error(
      "Failed to start metrics HTTP server",
      serverIp = serverIp,
      serverPort = serverPort,
      msg = e.msg,
    )

  info "Metrics HTTP server started", serverIp, serverPort
  ok()
