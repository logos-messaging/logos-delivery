{.used.}

import
  std/options,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/peerinfo,
  libp2p/multiaddress,
  libp2p/crypto/crypto
import
  waku/[
    waku_node,
    node/waku_node as waku_node2,
      # TODO: Remove after moving `git_version` to the app code.
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/debug/handlers as debug_rest_interface,
    rest_api/endpoint/debug/client as debug_rest_client,
  ],
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode

proc testWakuNode(): WakuNode =
  let
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

suite "Waku v2 REST API - Debug":
  asyncTest "Get node info - GET /info":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.debugInfoV1()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.listenAddresses ==
        @[$node.switch.peerInfo.addrs[^1] & "/p2p/" & $node.switch.peerInfo.peerId]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "GET /info exposes node.ports":
    let node = testWakuNode()
    node.ports = BoundPorts(
      tcp: some(1001'u16),
      webSocket: some(1002'u16),
      rest: some(1003'u16),
      discv5Udp: some(1004'u16),
      metrics: some(1005'u16),
    )

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    let client =
      newRestHttpClient(initTAddress(restAddress, restServer.httpServer.address.port))
    let response = await client.debugInfoV1()

    check:
      response.status == 200
      response.data.ports.tcp == some(1001'u16)
      response.data.ports.webSocket == some(1002'u16)
      response.data.ports.rest == some(1003'u16)
      response.data.ports.discv5Udp == some(1004'u16)
      response.data.ports.metrics == some(1005'u16)

  asyncTest "Get node version - GET /version":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.debugVersionV1()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == waku_node2.git_version

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
