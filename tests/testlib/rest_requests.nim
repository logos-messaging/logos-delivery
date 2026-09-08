import stew/byteutils, presto, presto/client as presto_client
import logos_delivery/waku/rest_api/endpoint/server

type TestResponseTuple* = tuple[status: int, data: string, headers: HttpTable]

proc fetchWithHeader*(
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

proc getAddress*(restServer: WakuRestServerRef, path: string): HttpAddress =
  getAddress(restServer.localAddress(), HttpClientScheme.NonSecure, path)

proc issueRequest*(
    address: HttpAddress,
    meth = MethodGet,
    headers: seq[HttpHeaderTuple] = @[],
    body = "",
): Future[TestResponseTuple] {.async.} =
  ## Sends the body as given, so an invalid one reaches the handler.
  var
    session = HttpSessionRef.new({HttpClientFlag.Http11Pipeline})
    data: TestResponseTuple

  var request = HttpClientRequestRef.new(
    session,
    address,
    meth,
    version = HttpVersion11,
    headers = headers,
    body = body.toBytes(),
  )
  try:
    data = await request.fetchWithHeader()
  finally:
    await request.closeWait()
    await session.closeWait()
  return data
