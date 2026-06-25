## Node connectivity (online/offline) status, fed by EventConnectionStatusChange.

proc onConnectionStatusChange*(
  status: string
) {.ffiEvent: "on_connection_status_change".}

proc listenConnectionStatusEvents(self: LogosDelivery) =
  discard EventConnectionStatusChange.listen(
    self.waku.brokerCtx,
    proc(e: EventConnectionStatusChange) {.async: (raises: []).} =
      onConnectionStatusChange($e.connectionStatus),
  )
