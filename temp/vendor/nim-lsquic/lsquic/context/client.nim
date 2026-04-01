# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import results
import chronicles
import chronos
import chronos/osdefs
import ./[context, io, stream]
import ../[lsquic_ffi, errors, tlsconfig, timeout, stream, certificates]
import ../helpers/sequninit

proc onNewConn(
    stream_if_ctx: pointer, conn: ptr lsquic_conn_t
): ptr lsquic_conn_ctx_t {.cdecl.} =
  debug "New connection established: client"
  let conn_ctx = lsquic_conn_get_ctx(conn)
  cast[ptr lsquic_conn_ctx_t](conn_ctx)

proc onHandshakeDone(
    conn: ptr lsquic_conn_t, status: enum_lsquic_hsk_status
) {.cdecl.} =
  debug "Handshake done", status
  let conn_ctx = lsquic_conn_get_ctx(conn)
  if conn_ctx.isNil:
    debug "conn_ctx is nil in onHandshakeDone"
    return

  let quicClientConn = cast[QuicConnection](conn_ctx)
  if quicClientConn.connectedFut.finished:
    return

  if status == LSQ_HSK_FAIL or status == LSQ_HSK_RESUMED_FAIL:
    quicClientConn.connectedFut.fail(
      newException(DialError, "could not connect to server. Handshake failed")
    )
  else:
    let x509chain = lsquic_conn_get_full_cert_chain(quicClientConn.lsquicConn)
    let certChain = x509chain.getCertChain()
    OPENSSL_sk_free(cast[ptr OPENSSL_STACK](x509chain))
    quicClientConn.certChain = certChain

    quicClientConn.connectedFut.complete()

proc onConnClosed(conn: ptr lsquic_conn_t) {.cdecl.} =
  debug "Connection closed: client"
  let conn_ctx = lsquic_conn_get_ctx(conn)
  if not conn_ctx.isNil:
    let quicClientConn = cast[QuicConnection](conn_ctx)
    if not quicClientConn.connectedFut.finished:
      # Not connected yet
      var buf: array[256, char]
      let connStatus =
        lsquic_conn_status(conn, cast[cstring](addr buf[0]), buf.len.csize_t)
      let msg = $cast[cstring](addr buf[0])
      quicClientConn.connectedFut.fail(
        newException(
          DialError, "could not connect to server. Status: " & $connStatus & ". " & msg
        )
      )
    quicClientConn.cancelPending()
    quicClientConn.lsquicConn = nil
    quicClientConn.onClose()
    GC_unref(quicClientConn)
  lsquic_conn_set_ctx(conn, nil)

method dial*(
    ctx: ClientContext,
    local: TransportAddress,
    remote: TransportAddress,
    connectedFut: Future[void],
    onClose: proc() {.gcsafe, raises: [].},
): Result[QuicConnection, string] {.raises: [], gcsafe.} =
  var
    localAddress: Sockaddr_storage
    localAddrLen: SockLen
    remoteAddress: Sockaddr_storage
    remoteAddrLen: SockLen

  local.toSAddr(localAddress, localAddrLen)
  remote.toSAddr(remoteAddress, remoteAddrLen)

  # TODO: should use constructor
  let quicClientConn = QuicConnection(
    isOutgoing: true,
    connectedFut: connectedFut,
    local: local,
    remote: remote,
    incoming: newAsyncQueue[Stream](),
    onClose: onClose,
  )
  GC_ref(quicClientConn) # Keep it pinned until on_conn_closed is called
  let conn = lsquic_engine_connect(
    ctx.engine,
    N_LSQVER,
    cast[ptr SockAddr](addr localAddress),
    cast[ptr SockAddr](addr remoteAddress),
    cast[pointer](ctx),
    cast[ptr lsquic_conn_ctx_t](quicClientConn),
    nil,
    0,
    nil,
    0,
    nil,
    0,
  )
  if conn.isNil:
    return err("could not dial: " & $remote)

  quicClientConn.lsquicConn = conn

  ok(quicClientConn)

const Cubic = 1

proc new*(T: typedesc[ClientContext], tlsConfig: TLSConfig): Result[T, string] =
  var ctx = ClientContext()
  ctx.tlsConfig = tlsConfig
  ctx.setupSSLContext()

  lsquic_engine_init_settings(addr ctx.settings, 0)
  ctx.settings.es_versions = 1.cuint shl LSQVER_I001.cuint #IETF QUIC v1
  ctx.settings.es_cc_algo = Cubic
  ctx.settings.es_dplpmtud = 1
  ctx.settings.es_base_plpmtu = 1280
  ctx.settings.es_max_plpmtu = 0
  ctx.settings.es_pace_packets = 1

  ctx.settings.es_cfcw = 1 * 1024 * 1024
  ctx.settings.es_max_cfcw = 2 * 1024 * 1024
  ctx.settings.es_sfcw = 256 * 1024
  ctx.settings.es_max_sfcw = 512 * 1024
  ctx.settings.es_init_max_stream_data_bidi_local = ctx.settings.es_sfcw
  ctx.settings.es_init_max_stream_data_bidi_remote = ctx.settings.es_sfcw
  ctx.settings.es_max_batch_size = 32

  ctx.stream_if = struct_lsquic_stream_if(
    on_new_conn: onNewConn,
    on_hsk_done: onHandshakeDone,
    on_conn_closed: onConnClosed,
    on_new_stream: onNewStream,
    on_read: onRead,
    on_write: onWrite,
    on_close: onClose,
  )
  ctx.api = struct_lsquic_engine_api(
    ea_settings: addr ctx.settings,
    ea_stream_if_ctx: cast[pointer](ctx),
    ea_packets_out_ctx: cast[pointer](ctx),
    ea_stream_if: addr ctx.stream_if,
    ea_get_ssl_ctx: getSSLCtx,
    ea_packets_out: sendPacketsOut,
  )

  ctx.engine = lsquic_engine_new(0, addr ctx.api)
  if ctx.engine.isNil:
    return err("failed to create lsquic engine")

  ctx.tickTimeout = newTimeout(
    proc() =
      ctx.engine_process()
  )
  ctx.tickTimeout.set(Moment.now())

  return ok(ctx)
