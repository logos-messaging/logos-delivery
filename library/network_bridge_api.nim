import logos_delivery/waku/net/net_bridge

proc logosdelivery_register_net_backend(
    name: cstring, table: ptr NetBackendTable, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  registerNetBackend(name, table, userData)

proc logosdelivery_net_backend_respond(
    requestId: uint64, ok: cint, data: cstring, len: csize_t
): cint {.dynlib, exportc, cdecl.} =
  ## The caller's thread owns `data` and may free it once this returns.
  if len > csize_t(int.high):
    return 1

  netBackendRespond(requestId, ok != 0, cast[pointer](data), int(len))
