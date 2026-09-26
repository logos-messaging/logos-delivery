import chronos, results

from logos_delivery/api/types import ConnectionStatus

# Structural API contract for the top-level entry point, implemented by
# `LogosDelivery` (the aggregate owning one instance of each API layer).
type LogosDeliveryApi* = concept ld
  # --- lifecycle ---
  start(ld) is Future[Result[void, string]]
  stop(ld) is Future[Result[void, string]]

  # --- health ---
  isOnline(ld) is Future[Result[bool, string]]
  getConnectionStatus(ld) is Future[Result[ConnectionStatus, string]]
