import chronicles, std/[net, options], results
import waku/factory/waku_conf

logScope:
  topics = "waku conf builder websocket"

##############################
## WebSocket Config Builder ##
##############################
type WebSocketConfBuilder* = object
  enabled*: Option[bool]
  webSocketPort*: Option[Port]
  secureEnabled*: Option[bool]
  keyPath*: Option[string]
  certPath*: Option[string]

proc init*(T: type WebSocketConfBuilder): WebSocketConfBuilder =
  WebSocketConfBuilder()

proc withEnabled*(b: var WebSocketConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withSecureEnabled*(b: var WebSocketConfBuilder, secureEnabled: bool) =
  b.secureEnabled = some(secureEnabled)
  if b.secureEnabled.get():
    b.enabled = some(true) # ws must be enabled to use wss

proc withWebSocketPort*(b: var WebSocketConfBuilder, webSocketPort: Port) =
  b.webSocketPort = some(webSocketPort)

proc withWebSocketPort*(b: var WebSocketConfBuilder, webSocketPort: uint16) =
  b.webSocketPort = some(Port(webSocketPort))

proc withKeyPath*(b: var WebSocketConfBuilder, keyPath: string) =
  b.keyPath = some(keyPath)

proc withCertPath*(b: var WebSocketConfBuilder, certPath: string) =
  b.certPath = some(certPath)

proc build*(b: WebSocketConfBuilder): Result[Option[WebSocketConf], string] =
  if not b.enabled.get(false):
    return ok(none(WebSocketConf))

  if not b.secureEnabled.get(false):
    return ok(
      some(
        WebSocketConf(
          port: b.webSocketPort.get(Port(0)), secureConf: none(WebSocketSecureConf)
        )
      )
    )

  if b.keyPath.get("") == "":
    return err("WebSocketSecure enabled but key path is not specified")
  if b.certPath.get("") == "":
    return err("WebSocketSecure enabled but cert path is not specified")

  return ok(
    some(
      WebSocketConf(
        port: b.webSocketPort.get(Port(0)),
        secureConf: some(
          WebSocketSecureConf(keyPath: b.keyPath.get(), certPath: b.certPath.get())
        ),
      )
    )
  )
