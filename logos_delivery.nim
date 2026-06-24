## Package entry point for using Logos Messaging as a Nimble library.
##
## This root module is a thin aggregator, following the standard Nimble layout:
## the implementation lives under `./logos_delivery/`, and importing the package
## name re-exports `LogosDelivery` together with every per-layer public API.
##
## See `logos_delivery/logos_delivery.nim` for `LogosDelivery`, the pure
## concentrator that owns one instance of each API layer
##
##   Waku  <-  MessagingClient  <-  ReliableChannelManager
##
## and drives their shared `new` / `start` / `stop` lifecycle.

import ./logos_delivery/logos_delivery as logos_delivery_impl
export logos_delivery_impl
