{.push raises: [].}

## RestService: the single owner of everything REST. It sits above the layers,
## like the FFI library does, wrapping a `LogosDelivery`: the HTTP server, the
## kernel routes, the messaging routes and the messaging event cache with its
## listeners all live and die here, so no layer knows about REST.
##
## `start` brings the server up with the health route (so probes answer while
## the node boots), `mount` installs the protocol routes once the node runs,
## and `stop` tears everything down. A fresh server is created on every
## `start`, so the service restarts as often as the node does.

import std/[net, strutils, tables]
import results, chronicles, chronos
import presto
import
  logos_delivery/logos_delivery,
  rest/rest_server_conf,
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_node,
  logos_delivery/waku/node/health_monitor,
  logos_delivery/waku/discovery/waku_discv5,
  logos_delivery/waku/waku_core/topics,
  logos_delivery/waku/waku_relay/protocol
import
  rest/message_cache,
  rest/discovery_handler,
  rest/route_hints,
  rest/server,
  rest/kernel_api/debug/handlers as rest_debug_endpoint,
  rest/kernel_api/relay/handlers as rest_relay_endpoint,
  rest/kernel_api/filter/handlers as rest_filter_endpoint,
  rest/kernel_api/legacy_lightpush/handlers as rest_legacy_lightpush_endpoint,
  rest/kernel_api/lightpush/handlers as rest_lightpush_endpoint,
  rest/kernel_api/store/handlers as rest_store_endpoint,
  rest/kernel_api/health/handlers as rest_health_endpoint,
  rest/kernel_api/admin/handlers as rest_admin_endpoint,
  rest/messaging_api/[event_cache, events, handlers as messaging_handlers]

export WakuRestServerRef, route_hints

logScope:
  topics = "rest service"

proc startRestServerEssentials(
    nodeHealthMonitor: NodeHealthMonitor, conf: rest_server_conf.RestServerConf
): Result[WakuRestServerRef, string] =
  let requestErrorHandler: RestRequestErrorHandler = proc(
      error: RestRequestError, request: HttpRequestRef
  ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    try:
      case error
      of RestRequestError.Invalid:
        return await request.respond(Http400, "Invalid request", HttpTable.init())
      of RestRequestError.NotFound:
        let paths = request.uri.path.split("/")
        let rootPath =
          if len(paths) > 1:
            paths[1]
          else:
            ""
        # chronos defaults to text/html.
        var headers = HttpTable.init()
        headers.add("Content-Type", "text/plain")
        let hint = hintFor(rootPath)
        if hint.len > 0:
          return await request.respond(Http404, hint, headers)
        return await request.respond(
          Http404, "Not found: invalid path or method used.", headers
        )
      of RestRequestError.InvalidContentBody:
        return await request.respond(Http400, "Invalid content body", HttpTable.init())
      of RestRequestError.InvalidContentType:
        return await request.respond(Http400, "Invalid content type", HttpTable.init())
      of RestRequestError.Unexpected:
        return defaultResponse()
    except HttpWriteError:
      debug "Failed to write response to client", error = getCurrentExceptionMsg()
      discard

    return defaultResponse()

  let allowedOrigin =
    if len(conf.allowOrigin) > 0:
      Opt.some(conf.allowOrigin.join(","))
    else:
      Opt.none(string)

  let address = conf.listenAddress
  let port = conf.port
  let server = ?newRestHttpServer(
    address,
    port,
    allowedOrigin = allowedOrigin,
    requestErrorHandler = requestErrorHandler,
  )

  ## Health REST API
  installHealthApiHandler(server.router, nodeHealthMonitor)

  markRestApiNotInstalled(
    RestRootAdmin, "/admin endpoints are not available while initializing."
  )
  markRestApiNotInstalled(
    RestRootDebug, "/debug endpoints are not available while initializing."
  )
  markRestApiNotInstalled(
    RestRootRelay, "/relay endpoints are not available while initializing."
  )
  markRestApiNotInstalled(
    RestRootFilter, "/filter endpoints are not available while initializing."
  )
  markRestApiNotInstalled(
    RestRootLightpush, "/lightpush endpoints are not available while initializing."
  )
  markRestApiNotInstalled(
    RestRootStore, "/store endpoints are not available while initializing."
  )
  markRestApiNotInstalled(
    RestRootMessaging, "/messaging endpoints are not available while initializing."
  )

  server.start()
  info "Starting REST HTTP server", url = "http://" & $address & ":" & $port & "/"

  ok(server)

proc installKernelRoutes(
    restServer: WakuRestServerRef,
    node: WakuNode,
    wakuDiscv5: WakuDiscoveryV5,
    conf: rest_server_conf.RestServerConf,
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
    markRestApiInstalled(RestRootAdmin)
  else:
    markRestApiNotInstalled(
      RestRootAdmin,
      "/admin endpoints are not available. Please check your configuration: --rest-admin=true",
    )

  ## Debug REST API
  installDebugApiHandlers(router, node)
  markRestApiInstalled(RestRootDebug)

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
        debug "Could not subscribe", pubsubTopic, error
        continue

    if node.wakuAutoSharding.isSome():
      # Only deduce pubsub topics to subscribe to from content topics if autosharding is enabled
      for contentTopic in contentTopics:
        cache.contentSubscribe(contentTopic)

        let shard = node.wakuAutoSharding.get().getShard(contentTopic).valueOr:
            debug "Autosharding error in REST", error = error
            continue
        let pubsubTopic = $shard

        node.subscribe((kind: PubsubSub, topic: pubsubTopic), handler).isOkOr:
          debug "Could not subscribe", pubsubTopic, error
          continue

    installRelayApiHandlers(router, node, cache)
    markRestApiInstalled(RestRootRelay)
  else:
    markRestApiNotInstalled(
      RestRootRelay,
      "/relay endpoints are not available. Please check your configuration: --relay",
    )

  ## Filter REST API
  if node.wakuFilterClient != nil:
    let filterCache = MessageCache.init()

    let filterDiscoHandler =
      if not wakuDiscv5.isNil():
        Opt.some(defaultDiscoveryHandler(wakuDiscv5, Filter))
      else:
        Opt.none(DiscoveryHandler)

    rest_filter_endpoint.installFilterRestApiHandlers(
      router, node, filterCache, filterDiscoHandler
    )
    markRestApiInstalled(RestRootFilter)
  else:
    markRestApiNotInstalled(RestRootFilter, "/filter endpoints are not available.")

  ## Store REST API
  let storeDiscoHandler =
    if not wakuDiscv5.isNil():
      Opt.some(defaultDiscoveryHandler(wakuDiscv5, Store))
    else:
      Opt.none(DiscoveryHandler)

  rest_store_endpoint.installStoreApiHandlers(router, node, storeDiscoHandler)
  markRestApiInstalled(RestRootStore)

  ## Light push API
  ## Install it either if client is mounted)
  ## or install it to be used with self-hosted lightpush service
  ## We either get lightpushnode (lightpush service node) from config or discovered or self served
  if (node.wakuLegacyLightpushClient != nil) or
      (lightPushEnabled and node.wakuLegacyLightPush != nil and node.wakuRelay != nil):
    let lightDiscoHandler =
      if not wakuDiscv5.isNil():
        Opt.some(defaultDiscoveryHandler(wakuDiscv5, Lightpush))
      else:
        Opt.none(DiscoveryHandler)

    rest_legacy_lightpush_endpoint.installLightPushRequestHandler(
      router, node, lightDiscoHandler
    )
    rest_lightpush_endpoint.installLightPushRequestHandler(
      router, node, lightDiscoHandler
    )
    markRestApiInstalled(RestRootLightpush)
  else:
    markRestApiNotInstalled(
      RestRootLightpush, "/lightpush endpoints are not available."
    )

  info "REST services are installed"
  return ok()

type RestService* = ref object
  node: LogosDelivery
  server*: WakuRestServerRef
  messagingEvents: MessagingRestEvents
    ## Set by `mount` when the node has a messaging layer.

proc new*(T: type RestService, node: LogosDelivery): T =
  return T(node: node)

proc isEnabled(self: RestService): bool =
  return self.node.waku.conf.restServerConf.isSome()

proc start*(self: RestService): Result[void, string] =
  ## Starts the HTTP server with the health route. No-op when REST is disabled
  ## in the node's configuration.
  if not self.isEnabled() or not self.server.isNil():
    return ok()

  let waku = self.node.waku
  let server = startRestServerEssentials(
    waku.healthMonitor, waku.conf.restServerConf.get()
  ).valueOr:
    return err("could not start the essential REST server: " & error)

  # Port 0 resolves on bind; keep the bound port so a restart reuses it.
  let boundPort = server.httpServer.address.port
  waku.node.ports.rest = boundPort.uint16
  waku.conf.restServerConf.get().port = boundPort
  self.server = server
  return ok()

proc mountMessaging(self: RestService): Result[void, string] =
  let client = self.node.messagingClient
  if client.isNil():
    # On a kernel-only node, /messaging answers 404 with the entry-layer hint.
    markRestApiNotInstalled(
      RestRootMessaging,
      "/messaging endpoints are not available. Please check your configuration: --entry-layer=messaging or --entry-layer=channels",
    )
    return ok()

  let capacity = int(self.node.waku.conf.restServerConf.get().messagingCacheCapacity)
  self.messagingEvents =
    MessagingRestEvents.new(MessagingEventCache.new(maxReceived = capacity))
  var router = self.server.router
  installMessagingApiHandlers(router, client, self.messagingEvents.cache)
  markRestApiInstalled(RestRootMessaging)
  info "Mounted messaging REST API endpoints"

  self.messagingEvents.start(client.brokerCtx).isOkOr:
    return err("could not start the messaging REST events: " & error)
  return ok()

proc mount*(self: RestService): Result[void, string] =
  ## Installs the protocol routes. Call it once the node is running.
  if self.server.isNil():
    return ok()

  let waku = self.node.waku
  let conf = waku.conf
  installKernelRoutes(
    self.server,
    waku.node,
    waku.wakuDiscv5,
    conf.restServerConf.get(),
    conf.relay,
    conf.lightPush,
    conf.clusterId,
    conf.subscribeShards,
    conf.contentTopics,
  ).isOkOr:
    return err("could not install the kernel REST routes: " & error)

  return self.mountMessaging()

proc isListeningToMessagingEvents*(self: RestService): bool =
  return not self.messagingEvents.isNil() and self.messagingEvents.isListening()

proc stop*(self: RestService) {.async: (raises: []).} =
  if self.server.isNil():
    return
  if not self.messagingEvents.isNil():
    await self.messagingEvents.stop(self.node.messagingClient.brokerCtx)
    self.messagingEvents = nil
  await self.server.stop()
  self.server = nil

proc startNode*(self: RestService): Future[Result[void, string]] {.async.} =
  ## Starts the node with REST around it: the server answers health probes
  ## while the node boots and gets its protocol routes once the node runs.
  ## REST is stopped again if the node does not start.
  ?self.start()
  (await self.node.start()).isOkOr:
    await self.stop()
    return err("could not start the node: " & error)
  return self.mount()

proc stopNode*(self: RestService): Future[Result[void, string]] {.async.} =
  ## Stops REST first, so no route is served while the node shuts down, then
  ## the node.
  await self.stop()
  return await self.node.stop()
