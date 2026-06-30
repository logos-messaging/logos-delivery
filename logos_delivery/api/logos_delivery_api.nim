## `LogosDelivery` is the project entry point. It is a pure concentrator: it
## owns exactly one instance of each API layer
##
##   Waku  <-  MessagingClient  <-  ReliableChannelManager
##
## and chains them together (each layer drives the one below it). Every layer
## keeps its own, separate public API — `LogosDelivery` only wires them up and
## drives the shared `new` / `start` / `stop` lifecycle.

{.push raises: [].}

import results, chronos
import brokers/event_broker
import types as api_types

export api_types, event_broker

type
  ## Entry point. Holds one instance of each API layer.
  ILogosDelivery* = ref object of RootObj

EventBroker:
  type EventConnectionStatusChange* = object
    connectionStatus*: ConnectionStatus

method start*(self: ILogosDelivery): Future[Result[void, string]] {.async, base.} =
  return err("ILogosDelivery.start not implemented")

method stop*(self: ILogosDelivery): Future[Result[void, string]] {.async, base.} =
  return err("ILogosDelivery.stop not implemented")

method isOnline*(self: ILogosDelivery): Future[Result[bool, string]] {.async, base.} =
  return err("ILogosDelivery.isOnline not implemented")
