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

# `EventConnectionStatusChange` lives in the decomposed health-events module.
# Re-export it here so the orchestrator surfaces it without duplicating the type.
import logos_delivery/waku/api/events/health_events as health_events

export api_types, event_broker
export health_events

type
  ## Entry point. Holds one instance of each API layer.
  ILogosDelivery* = ref object of RootObj

method start*(self: ILogosDelivery): Future[Result[void, string]] {.async, base.} =
  return err("ILogosDelivery.start not implemented")

method stop*(self: ILogosDelivery): Future[Result[void, string]] {.async, base.} =
  return err("ILogosDelivery.stop not implemented")

method isOnline*(self: ILogosDelivery): Future[Result[bool, string]] {.async, base.} =
  return err("ILogosDelivery.isOnline not implemented")
