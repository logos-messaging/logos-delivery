{.push raises: [].}

import std/[httpclient, json, uri, options], results

const
  # Resource locators
  stream* = "/api/stream"
  messages* = "/api/messages"
  message* = "/api/message"
  health* = "/api/health"

type
  MatterbridgeResult[T] = Result[T, string]

  MatterbridgeClient* = ref object of RootObj
    hostClient*: HttpClient
    host*: Uri
    gateway*: string

proc new*(
    T: type MatterbridgeClient, hostUri: string, gateway = "gateway1"
): MatterbridgeClient {.raises: [Defect, KeyError].} =
  let mbClient = MatterbridgeClient()

  mbClient.hostClient = newHttpClient()
  mbClient.hostClient.headers = newHttpHeaders({"Content-Type": "application/json"})

  mbClient.host = parseUri(hostUri)
  mbClient.gateway = gateway

  return mbClient

proc getMessages*(mb: MatterbridgeClient): MatterbridgeResult[seq[JsonNode]] =
  var
    response: Response
    msgs: seq[JsonNode]
  try:
    response = mb.hostClient.get($(mb.host / messages))
    msgs = parseJson(response.body()).getElems()
  except Exception as e:
    return err("failed to get messages: " & e.msg)

  assert response.status == "200 OK"

  ok(msgs)

proc postMessage*(mb: MatterbridgeClient, msg: JsonNode): MatterbridgeResult[bool] =
  var response: Response
  try:
    response =
      mb.hostClient.request($(mb.host / message), httpMethod = HttpPost, body = $msg)
  except Exception as e:
    return err("post request failed: " & e.msg)

  ok(response.status == "200 OK")

proc postMessage*(
    mb: MatterbridgeClient, text: string, username: string
): MatterbridgeResult[bool] =
  let jsonNode = %*{"text": text, "username": username, "gateway": mb.gateway}

  return mb.postMessage(jsonNode)

proc isHealthy*(mb: MatterbridgeClient): MatterbridgeResult[bool] =
  var
    response: Response
    healthOk: bool
  try:
    response = mb.hostClient.get($(mb.host / health))
    healthOk = response.body == "OK"
  except Exception as e:
    return err("failed to get health: " & e.msg)

  ok(response.status == "200 OK" and healthOk)
