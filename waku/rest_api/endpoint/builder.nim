{.push raises: [].}

import net, tables
import presto
import
  waku/waku_node,
  waku/discovery/waku_discv5,
  waku/rest_api/message_cache,
  waku/rest_api/handlers,
  waku/rest_api/endpoint/server,
  waku/rest_api/endpoint/debug/handlers as rest_debug_endpoint,
  waku/rest_api/endpoint/relay/handlers as rest_relay_endpoint,
  waku/rest_api/endpoint/filter/handlers as rest_filter_endpoint,
  waku/rest_api/endpoint/legacy_lightpush/handlers as rest_legacy_lightpush_endpoint,
  waku/rest_api/endpoint/lightpush/handlers as rest_lightpush_endpoint,
  waku/rest_api/endpoint/store/handlers as rest_store_endpoint,
  waku/rest_api/endpoint/legacy_store/handlers as rest_store_legacy_endpoint,
  waku/rest_api/endpoint/health/handlers as rest_health_endpoint,
  waku/rest_api/endpoint/admin/handlers as rest_admin_endpoint,
  waku/waku_core/topics,
  waku/waku_relay/protocol

## Monitoring and external interfaces

# Used to register api endpoints that are not currently installed as keys,
# values are holding error messages to be returned to the client
# NOTE: {.threadvar.} is used to make the global variable GC safe for the closure uses it
# It will always be called from main thread anyway.
# Ref: https://nim-lang.org/docs/manual.html#threads-gc-safety
var restServerNotInstalledTab {.threadvar.}: TableRef[string, string]
restServerNotInstalledTab = newTable[string, string]()

export WakuRestServerRef

type RestServerConf* = object
  allowOrigin*: seq[string]
  listenAddress*: IpAddress
  port*: Port
  admin*: bool
  relayCacheCapacity*: uint32

proc startRestServerEssentials*(
    nodeHealthMonitor: NodeHealthMonitor, conf: RestServerConf, portsShift: uint16
): Result[WakuRestServerRef, string] =
  let requestErrorHandler: RestRequestErrorHandler = proc(
      error: RestRequestError, request: HttpRequestRef
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    try:
      case error
      of RestRequestError.Invalid:
        return await request.respond(Http400, "Invalid request", HttpTable.init())
      of RestRequestError.NotFound:
        let paths = request.rawPath.split("/")
        let rootPath =
          if len(paths) > 1:
            paths[1]
          else:
            ""
        restServerNotInstalledTab[].withValue(rootPath, errMsg):
          return await request.respond(Http404, errMsg[], HttpTable.init())
        do:
          return await request.respond(
            Http400,
            "Bad request initiated. Invalid path or method used.",
            HttpTable.init(),
          )
      of RestRequestError.InvalidContentBody:
        return await request.respond(Http400, "Invalid content body", HttpTable.init())
      of RestRequestError.InvalidContentType:
        return await request.respond(Http400, "Invalid content type", HttpTable.init())
      of RestRequestError.Unexpected:
        return defaultResponse()
    except HttpWriteError:
      error "Failed to write response to client", error = getCurrentExceptionMsg()
      discard

    return defaultResponse()

  let allowedOrigin =
    if len(conf.allowOrigin) > 0:
      some(conf.allowOrigin.join(","))
    else:
      none(string)

  let address = conf.listenAddress
  let port = Port(conf.port.uint16 + portsShift)
  let server = ?newRestHttpServer(
    address,
    port,
    allowedOrigin = allowedOrigin,
    requestErrorHandler = requestErrorHandler,
  )

  ## Health REST API
  installHealthApiHandler(server.router, nodeHealthMonitor)

  restServerNotInstalledTab["admin"] =
    "/admin endpoints are not available while initializing."
  restServerNotInstalledTab["debug"] =
    "/debug endpoints are not available while initializing."
  restServerNotInstalledTab["relay"] =
    "/relay endpoints are not available while initializing."
  restServerNotInstalledTab["filter"] =
    "/filter endpoints are not available while initializing."
  restServerNotInstalledTab["lightpush"] =
    "/lightpush endpoints are not available while initializing."
  restServerNotInstalledTab["store"] =
    "/store endpoints are not available while initializing."

  server.start()
  info "Starting REST HTTP server", url = "http://" & $address & ":" & $port & "/"

  ok(server)

proc startRestServerProtocolSupport*(
    restServer: WakuRestServerRef,
    node: WakuNode,
    wakuDiscv5: WakuDiscoveryV5,
    conf: RestServerConf,
    relayEnabled: bool,
    lightPushEnabled: bool,
    clusterId: uint16,
    shards: seq[uint16],
    contentTopics: seq[string],
): Result[void, string] =
  var router = restServer.router
  ## Admin REST API
  if conf.admin:
    installAdminApiHandlers(router, node)
  else:
    restServerNotInstalledTab["admin"] =
      "/admin endpoints are not available. Please check your configuration: --rest-admin=true"

  ## Debug REST API
  installDebugApiHandlers(router, node)

  ## Relay REST API
  if relayEnabled:
    ## This MessageCache is used, f.e., in js-waku<>nwaku interop tests.
    ## js-waku tests asks nwaku-docker through REST whether a message is properly received.
    let cache = MessageCache.init(int(conf.relayCacheCapacity))

    let handler: WakuRelayHandler = messageCacheHandler(cache)

    for shard in shards:
      let pubsubTopic = $RelayShard(clusterId: clusterId, shardId: shard)
      cache.pubsubSubscribe(pubsubTopic)

      node.subscribe((kind: PubsubSub, topic: pubsubTopic), handler).isOkOr:
        error "Could not subscribe", pubsubTopic, error
        continue

    if node.wakuAutoSharding.isSome():
      # Only deduce pubsub topics to subscribe to from content topics if autosharding is enabled
      for contentTopic in contentTopics:
        cache.contentSubscribe(contentTopic)

        let shard = node.wakuAutoSharding.get().getShard(contentTopic).valueOr:
            error "Autosharding error in REST", error = error
            continue
        let pubsubTopic = $shard

        node.subscribe((kind: PubsubSub, topic: pubsubTopic), handler).isOkOr:
          error "Could not subscribe", pubsubTopic, error
          continue

    installRelayApiHandlers(router, node, cache)
  else:
    restServerNotInstalledTab["relay"] =
      "/relay endpoints are not available. Please check your configuration: --relay"

  ## Filter REST API
  if node.wakuFilterClient != nil:
    let filterCache = MessageCache.init()

    let filterDiscoHandler =
      if not wakuDiscv5.isNil():
        some(defaultDiscoveryHandler(wakuDiscv5, Filter))
      else:
        none(DiscoveryHandler)

    rest_filter_endpoint.installFilterRestApiHandlers(
      router, node, filterCache, filterDiscoHandler
    )
  else:
    restServerNotInstalledTab["filter"] = "/filter endpoints are not available."

  ## Store REST API
  let storeDiscoHandler =
    if not wakuDiscv5.isNil():
      some(defaultDiscoveryHandler(wakuDiscv5, Store))
    else:
      none(DiscoveryHandler)

  rest_store_endpoint.installStoreApiHandlers(router, node, storeDiscoHandler)
  rest_store_legacy_endpoint.installStoreApiHandlers(router, node, storeDiscoHandler)

  ## Light push API
  ## Install it either if client is mounted)
  ## or install it to be used with self-hosted lightpush service
  ## We either get lightpushnode (lightpush service node) from config or discovered or self served
  if (node.wakuLegacyLightpushClient != nil) or
      (lightPushEnabled and node.wakuLegacyLightPush != nil and node.wakuRelay != nil):
    let lightDiscoHandler =
      if not wakuDiscv5.isNil():
        some(defaultDiscoveryHandler(wakuDiscv5, Lightpush))
      else:
        none(DiscoveryHandler)

    rest_legacy_lightpush_endpoint.installLightPushRequestHandler(
      router, node, lightDiscoHandler
    )
    rest_lightpush_endpoint.installLightPushRequestHandler(
      router, node, lightDiscoHandler
    )
  else:
    restServerNotInstalledTab["lightpush"] = "/lightpush endpoints are not available."

  info "REST services are installed"
  return ok()
