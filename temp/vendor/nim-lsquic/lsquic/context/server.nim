# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import results
import chronicles
import chronos
import chronos/osdefs
import ./[context, io, stream]
import ../[lsquic_ffi, tlsconfig, timeout, stream, certificates]
import ../helpers/[sequninit, transportaddr]

proc onNewConn(
    stream_if_ctx: pointer, conn: ptr lsquic_conn_t
): ptr lsquic_conn_ctx_t {.cdecl.} =
  debug "New connection established: server"
  var local: ptr SockAddr
  var remote: ptr SockAddr
  discard lsquic_conn_get_sockaddr(conn, addr local, addr remote)

  let x509chain = lsquic_conn_get_full_cert_chain(conn)
  let certChain = x509chain.getCertChain()
  OPENSSL_sk_free(cast[ptr OPENSSL_STACK](x509chain))

  # TODO: should use a constructor
  let quicConn = QuicConnection(
    isOutgoing: false,
    incoming: newAsyncQueue[Stream](),
    local: local.toTransportAddress(),
    remote: remote.toTransportAddress(),
    lsquicConn: conn,
    certChain: certChain,
    onClose: proc() =
      discard,
  )
  GC_ref(quicConn) # Keep it pinned until on_conn_closed is called
  let serverCtx = cast[ServerContext](stream_if_ctx)
  serverCtx.incoming.putNoWait(quicConn)
  cast[ptr lsquic_conn_ctx_t](quicConn)

proc onConnClosed(conn: ptr lsquic_conn_t) {.cdecl.} =
  debug "Connection closed: server"
  let conn_ctx = lsquic_conn_get_ctx(conn)
  if not conn_ctx.isNil:
    let quicConn = cast[QuicConnection](conn_ctx)
    quicConn.lsquicConn = nil
    quicConn.onClose()
    GC_unref(quicConn)
  lsquic_conn_set_ctx(conn, nil)

const Cubic = 1

proc new*(T: typedesc[ServerContext], tlsConfig: TLSConfig): Result[T, string] =
  var ctx = ServerContext()
  ctx.tlsConfig = tlsConfig
  ctx.incoming = newAsyncQueue[QuicConnection]()
  ctx.setupSSLContext()

  lsquic_engine_init_settings(addr ctx.settings, LSENG_SERVER)
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

  ctx.engine = lsquic_engine_new(LSENG_SERVER, addr ctx.api)
  if ctx.engine.isNil:
    return err("failed to create lsquic engine")

  ctx.tickTimeout = newTimeout(
    proc() =
      ctx.engine_process()
  )
  ctx.tickTimeout.set(Moment.now())

  return ok(ctx)
