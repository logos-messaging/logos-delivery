import chronicles, std/net, results
import logos_delivery/waku/factory/waku_conf

logScope:
  topics = "waku conf builder websocket"

const
  DefaultWebSocketEnabled: bool = false
  DefaultWebSocketSecureEnabled: bool = false
  DefaultWebSocketPort: Port = Port(8000)

##############################
## WebSocket Config Builder ##
##############################
type WebSocketConfBuilder* = object
  enabled*: Opt[bool]
  webSocketPort*: Opt[Port]
  secureEnabled*: Opt[bool]
  keyPath*: Opt[string]
  certPath*: Opt[string]

proc init*(T: type WebSocketConfBuilder): WebSocketConfBuilder =
  WebSocketConfBuilder()

proc withEnabled*(b: var WebSocketConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withSecureEnabled*(b: var WebSocketConfBuilder, secureEnabled: bool) =
  b.secureEnabled = Opt.some(secureEnabled)
  if b.secureEnabled.get():
    b.enabled = Opt.some(true) # ws must be enabled to use wss

proc withWebSocketPort*(b: var WebSocketConfBuilder, webSocketPort: Port) =
  b.webSocketPort = Opt.some(webSocketPort)

proc withWebSocketPort*(b: var WebSocketConfBuilder, webSocketPort: uint16) =
  b.webSocketPort = Opt.some(Port(webSocketPort))

proc withKeyPath*(b: var WebSocketConfBuilder, keyPath: string) =
  b.keyPath = Opt.some(keyPath)

proc withCertPath*(b: var WebSocketConfBuilder, certPath: string) =
  b.certPath = Opt.some(certPath)

proc build*(b: WebSocketConfBuilder): Result[Opt[WebSocketConf], string] =
  if not b.enabled.get(DefaultWebSocketEnabled):
    return ok(Opt.none(WebSocketConf))

  if not b.secureEnabled.get(DefaultWebSocketSecureEnabled):
    return ok(
      Opt.some(
        WebSocketConf(
          port: b.webSocketPort.get(DefaultWebSocketPort),
          secureConf: Opt.none(WebSocketSecureConf),
        )
      )
    )

  if b.keyPath.get("") == "":
    return err("WebSocketSecure enabled but key path is not specified")
  if b.certPath.get("") == "":
    return err("WebSocketSecure enabled but cert path is not specified")

  return ok(
    Opt.some(
      WebSocketConf(
        port: b.webSocketPort.get(DefaultWebSocketPort),
        secureConf: Opt.some(
          WebSocketSecureConf(keyPath: b.keyPath.get(), certPath: b.certPath.get())
        ),
      )
    )
  )
