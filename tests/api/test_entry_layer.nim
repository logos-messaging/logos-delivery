{.used.}

import std/[options, net]
import chronos, testutils/unittests, presto, presto/client as presto_client
import brokers/broker_context
import logos_delivery
import
  logos_delivery/api/conf/logos_delivery_conf,
  logos_delivery/messaging/rest_api/client as messaging_rest_client,
  logos_delivery/waku/rest_api/endpoint/client
import tools/confutils/cli_args
import ../testlib/testasync

## Validates the layer-selection invariant of `LogosDelivery.new(WakuNodeConf)`:
## `messagingClient` (and `reliableChannelManager`) are instantiated only for the
## entry layers that call for them.
##
##   kernel    -> waku only
##   messaging -> waku + messagingClient
##   channels  -> waku + messagingClient + reliableChannelManager

proc nodeConf(entryLayer: EntryLayer, rest = false): WakuNodeConf =
  var conf = defaultWakuNodeConf().valueOr:
    raiseAssert error
  conf.entryLayer = entryLayer
  conf.mode = LogosDeliveryMode.Core
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = Opt.some(3'u16)
  conf.numShardsInNetwork = 1
  conf.rest = rest
  conf.restAddress = parseIpAddress("127.0.0.1")
  conf.restPort = 0'u16 # bind to an ephemeral port
  return conf

proc restClientFor(node: LogosDelivery): RestClientRef =
  let boundPort = node.waku.restServer.httpServer.address.port
  newRestHttpClient(initTAddress(parseIpAddress("127.0.0.1"), boundPort))

suite "LogosDelivery - entry layer selection":
  asyncTest "kernel: waku only, no messaging / channels":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.kernel))).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      node.messagingClient.isNil()
      node.reliableChannelManager.isNil()
      node.ensureMessaging().isErr()
      node.ensureChannels().isErr()
    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "messaging: waku + messagingClient, no channels":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.messaging))).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      not node.messagingClient.isNil()
      node.reliableChannelManager.isNil()
      node.ensureMessaging().isOk()
      node.ensureChannels().isErr()
    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "channels: full stack":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.channels))).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      not node.messagingClient.isNil()
      not node.reliableChannelManager.isNil()
      node.ensureMessaging().isOk()
      node.ensureChannels().isOk()
    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "messaging + rest: messaging REST endpoints are installed and working":
    ## entry-layer=messaging, mode=Core, rest=true -> `start` mounts the messaging
    ## REST endpoints; they respond over HTTP.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.messaging, rest = true))).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error

    check not node.messagingClient.isNil()

    let client = restClientFor(node)

    # A command endpoint and an observability endpoint both respond -> the
    # handlers were installed onto the kernel router.
    let subResp =
      await client.messagingPostSubscriptionsV1(@["/test/1/entry-layer/proto"])
    check subResp.status == 200

    let sendEventsResp = await client.messagingGetSendEventsV1()
    check sendEventsResp.status == 200

    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "kernel + rest: messaging REST endpoints are NOT installed":
    ## Gating check: a kernel-only node still starts a REST server, but the
    ## messaging endpoints must be absent (no messaging client to mount them).
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.kernel, rest = true))).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error

    check node.messagingClient.isNil()

    let client = restClientFor(node)
    let subResp =
      await client.messagingPostSubscriptionsV1(@["/test/1/entry-layer/proto"])
    check subResp.status == 404 # route not mounted

    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error
