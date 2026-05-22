{.used.}

import
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
    rest_api/endpoint/server,
    rest_api/endpoint/debug/handlers as debug_rest_interface,
  ],
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode

type TestResponseTuple = tuple[status: int, data: string, headers: HttpTable]

proc testWakuNode(): WakuNode =
  let
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

proc fetchWithHeader(
    request: HttpClientRequestRef
): Future[TestResponseTuple] {.async: (raises: [CancelledError, HttpError]).} =
  var response: HttpClientResponseRef
  try:
    response = await request.send()
    let buffer = await response.getBodyBytes()
    let status = response.status
    let headers = response.headers
    await response.closeWait()
    response = nil
    return (status, buffer.bytesToString(), headers)
  except HttpError as exc:
    if not (isNil(response)):
      await response.closeWait()
    assert false
  except CancelledError as exc:
    if not (isNil(response)):
      await response.closeWait()
    assert false

proc issueRequest(
    address: HttpAddress, reqOrigin: Option[string] = none(string)
): Future[TestResponseTuple] {.async.} =
  var
    session = HttpSessionRef.new({HttpClientFlag.Http11Pipeline})
    data: TestResponseTuple

  var originHeader: seq[HttpHeaderTuple]
  if reqOrigin.isSome():
    originHeader.insert(("Origin", reqOrigin.get()))

  var request = HttpClientRequestRef.new(
    session, address, version = HttpVersion11, headers = originHeader
  )
  try:
    data = await request.fetchWithHeader()
  finally:
    await request.closeWait()
  return data

proc checkResponse(
    response: TestResponseTuple, expectedStatus: int, expectedOrigin: Option[string]
): bool =
  if response.status != expectedStatus:
    echo(
      " -> check failed: expected status" & $expectedStatus & " got " & $response.status
    )
    return false

  if not (
    expectedOrigin.isNone() or (
      expectedOrigin.isSome() and
      response.headers.contains("Access-Control-Allow-Origin") and
      response.headers.getLastString("Access-Control-Allow-Origin") ==
      expectedOrigin.get() and response.headers.contains("Access-Control-Allow-Headers") and
      response.headers.getLastString("Access-Control-Allow-Headers") == "Content-Type"
    )
  ):
    echo(
      " -> check failed: expected origin " & $expectedOrigin & " got " &
        response.headers.getLastString("Access-Control-Allow-Origin")
    )
    return false

  return true

suite "Waku v2 REST API CORS Handling":
  asyncTest "AllowedOrigin matches":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef
      .init(
        restAddress,
        restPort,
        allowedOrigin =
          some("test.net:1234,https://localhost:*,http://127.0.0.1:?8,?waku*.net:*80*"),
      )
      .tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    let srvAddr = restServer.localAddress()
    let ha = getAddress(srvAddr, HttpClientScheme.NonSecure, "/debug/v1/info")

    # When
    var response = await issueRequest(ha, some("http://test.net:1234"))
    check checkResponse(response, 200, some("http://test.net:1234"))

    response = await issueRequest(ha, some("https://test.net:1234"))
    check checkResponse(response, 200, some("https://test.net:1234"))

    response = await issueRequest(ha, some("https://localhost:8080"))
    check checkResponse(response, 200, some("https://localhost:8080"))

    response = await issueRequest(ha, some("https://localhost:80"))
    check checkResponse(response, 200, some("https://localhost:80"))

    response = await issueRequest(ha, some("http://127.0.0.1:78"))
    check checkResponse(response, 200, some("http://127.0.0.1:78"))

    response = await issueRequest(ha, some("http://wakuTHE.net:8078"))
    check checkResponse(response, 200, some("http://wakuTHE.net:8078"))

    response = await issueRequest(ha, some("http://nwaku.main.net:1980"))
    check checkResponse(response, 200, some("http://nwaku.main.net:1980"))

    response = await issueRequest(ha, some("http://nwaku.main.net:80"))
    check checkResponse(response, 200, some("http://nwaku.main.net:80"))

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "AllowedOrigin reject":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef
      .init(
        restAddress,
        restPort,
        allowedOrigin =
          some("test.net:1234,https://localhost:*,http://127.0.0.1:?8,?waku*.net:*80*"),
      )
      .tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    let srvAddr = restServer.localAddress()
    let ha = getAddress(srvAddr, HttpClientScheme.NonSecure, "/debug/v1/info")

    # When
    var response = await issueRequest(ha, some("http://test.net:12334"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("http://test.net:12345"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("xhttp://test.net:1234"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("https://xtest.net:1234"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("http://localhost:8080"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("https://127.0.0.1:78"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("http://127.0.0.1:89"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("http://the.waku.net:8078"))
    check checkResponse(response, 403, none(string))

    response = await issueRequest(ha, some("http://nwaku.main.net:1900"))
    check checkResponse(response, 403, none(string))

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "AllowedOrigin allmatches":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer =
      WakuRestServerRef.init(restAddress, restPort, allowedOrigin = some("*")).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    let srvAddr = restServer.localAddress()
    let ha = getAddress(srvAddr, HttpClientScheme.NonSecure, "/debug/v1/info")

    # When
    var response = await issueRequest(ha, some("http://test.net:1234"))
    check checkResponse(response, 200, some("*"))

    response = await issueRequest(ha, some("https://test.net:1234"))
    check checkResponse(response, 200, some("*"))

    response = await issueRequest(ha, some("https://localhost:8080"))
    check checkResponse(response, 200, some("*"))

    response = await issueRequest(ha, some("https://localhost:80"))
    check checkResponse(response, 200, some("*"))

    response = await issueRequest(ha, some("http://127.0.0.1:78"))
    check checkResponse(response, 200, some("*"))

    response = await issueRequest(ha, some("http://wakuTHE.net:8078"))
    check checkResponse(response, 200, some("*"))

    response = await issueRequest(ha, some("http://nwaku.main.net:1980"))
    check checkResponse(response, 200, some("*"))

    response = await issueRequest(ha, some("http://nwaku.main.net:80"))
    check checkResponse(response, 200, some("*"))

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "No origin goes through":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef
      .init(
        restAddress,
        restPort,
        allowedOrigin =
          some("test.net:1234,https://localhost:*,http://127.0.0.1:?8,?waku*.net:*80*"),
      )
      .tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    installDebugApiHandlers(restServer.router, node)
    restServer.start()

    let srvAddr = restServer.localAddress()
    let ha = getAddress(srvAddr, HttpClientScheme.NonSecure, "/debug/v1/info")

    # When
    var response = await issueRequest(ha, none(string))
    check checkResponse(response, 200, none(string))

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
