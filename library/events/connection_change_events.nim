## Per-peer connection changes (connected/disconnected/…), fed by WakuPeerEvent.

proc onConnectionChange*(
  peerId: string, event: string
) {.ffiEvent: "on_connection_change".}

proc listenConnectionChangeEvents(self: LogosDelivery) =
  discard WakuPeerEvent.listen(
    self.waku.brokerCtx,
    proc(e: WakuPeerEvent) {.async: (raises: []).} =
      onConnectionChange($e.peerId, $e.kind),
  )
