# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos
import chronos/osdefs
import chronicles
import
  ../[lsquic_ffi, errors, tlsconfig, timeout, certificates, certificateverifier, stream]

let SSL_CTX_ID = SSL_CTX_get_ex_new_index(0, nil, nil, nil, nil) # Yes, this is global
doAssert SSL_CTX_ID >= 0, "could not generate global ssl_ctx id"

type QuicContext* = ref object of RootObj
  settings*: struct_lsquic_engine_settings
  api*: struct_lsquic_engine_api
  engine*: ptr struct_lsquic_engine
  stream_if*: struct_lsquic_stream_if
  tlsConfig*: TLSConfig
  tickTimeout*: Timeout
  sslCtx*: ptr SSL_CTX
  fd*: cint

proc engine_process*(ctx: QuicContext) =
  lsquic_engine_process_conns(ctx.engine)

  if lsquic_engine_has_unsent_packets(ctx.engine) != 0:
    lsquic_engine_send_unsent_packets(ctx.engine)

  var diff: cint
  if lsquic_engine_earliest_adv_tick(ctx.engine, addr diff) == 0:
    return

  let delta =
    if diff < 0: LSQUIC_DF_CLOCK_GRANULARITY.microseconds else: diff.microseconds
  ctx.tickTimeout.set(delta)

type PendingStream = object
  stream: Stream
  created: Future[void].Raising([CancelledError, ConnectionError])

type QuicConnection* = ref object of RootObj
  isOutgoing*: bool
  local*: TransportAddress
  remote*: TransportAddress
  lsquicConn*: ptr lsquic_conn_t
  onClose*: proc() {.gcsafe, raises: [].}
  closedLocal*: bool
  closedRemote*: bool
  incoming*: AsyncQueue[Stream]
  connectedFut*: Future[void]
  pendingStreams: seq[PendingStream]
  certChain*: seq[seq[byte]]

type ClientContext* = ref object of QuicContext

type ServerContext* = ref object of QuicContext
  incoming*: AsyncQueue[QuicConnection]

proc processWhenReady*(quicContext: QuicContext) =
  quicContext.tickTimeout.set(Moment.now())

proc incomingStream*(
    quicConn: QuicConnection
): Future[Stream] {.async: (raises: [CancelledError]).} =
  await quicConn.incoming.get()

proc addPendingStream*(
    quicConn: QuicConnection, s: Stream
): Future[void].Raising([CancelledError, ConnectionError]) {.raises: [], gcsafe.} =
  let created = Future[void].Raising([CancelledError, ConnectionError]).init(
      "QuicConnection.addPendingStream"
    )
  quicConn.pendingStreams.add(PendingStream(stream: s, created: created))
  created

proc popPendingStream*(
    quicConn: QuicConnection, stream: ptr lsquic_stream_t
): Opt[Stream] {.raises: [], gcsafe.} =
  if quicConn.pendingStreams.len == 0:
    debug "no pending streams!"
    return Opt.none(Stream)

  let pending = quicConn.pendingStreams.pop()
  pending.stream.quicStream = stream
  pending.created.complete()
  Opt.some(pending.stream)

proc cancelPending*(quicConn: QuicConnection) =
  for pending in quicConn.pendingStreams:
    pending.created.fail(newException(ConnectionError, "can't open new streams"))

proc alpnSelectProtoCB(
    ssl: ptr SSL,
    outv: ptr ptr uint8,
    outlen: ptr uint8,
    inv: ptr uint8,
    inlen: cuint,
    userData: pointer,
): cint {.cdecl.} =
  let serverCtx = cast[ServerContext](userData)

  if (
    SSL_select_next_proto(
      outv,
      outlen,
      cast[ptr uint8](serverCtx.tlsConfig.alpnWire.cstring),
      cast[cuint](serverCtx.tlsConfig.alpnWire.len),
      inv,
      inlen,
    ) == OPENSSL_NPN_NEGOTIATED
  ):
    return SSL_TLSEXT_ERR_OK

  return SSL_TLSEXT_ERR_ALERT_FATAL

proc verifyCertificate(
    ssl: ptr SSL, out_alert: ptr uint8
): enum_ssl_verify_result_t {.cdecl.} =
  let sslCtx = SSL_get_SSL_CTX(ssl)

  let quicCtx = cast[QuicContext](SSL_CTX_get_ex_data(sslCtx, SSL_CTX_ID))
  if quicCtx.isNil:
    raiseAssert "could not obtain context"

  let derCertificates = getFullCertChain(ssl)

  let serverName = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name)
  doAssert quicCtx.tlsConfig.certVerifier.isSome, "no custom validator set"
  if quicCtx.tlsConfig.certVerifier.get().verify($serverName, derCertificates):
    return ssl_verify_ok
  else:
    out_alert[] = SSL_AD_CERTIFICATE_UNKNOWN
    return ssl_verify_invalid

proc setupSSLContext*(quicCtx: QuicContext) =
  let sslCtx = SSL_CTX_new(
    if quicCtx is ServerContext:
      TLS_server_method()
    else:
      TLS_client_method()
  )
  if sslCtx.isNil:
    raiseAssert "failed to create sslCtx"

  if SSL_CTX_set_ex_data(sslCtx, SSL_CTX_ID, cast[pointer](quicCtx)) != 1:
    raiseAssert "could not set data in sslCtx"

  var opts =
    0 or SSL_OP_NO_SSLv2 or SSL_OP_NO_SSLv3 or SSL_OP_NO_TLSv1 or SSL_OP_NO_TLSv1_1 or
    SSL_OP_CIPHER_SERVER_PREFERENCE
  discard SSL_CTX_set_options(sslCtx, opts.uint32)

  if quicCtx.tlsConfig.key.len != 0 and quicCtx.tlsConfig.certificate.len != 0:
    let pkey = quicCtx.tlsConfig.key.toPKey().valueOr:
      raiseAssert "could not convert certificate to pkey: " & error

    let cert = quicCtx.tlsConfig.certificate.toX509().valueOr:
      raiseAssert "could not convert certificate to x509: " & error

    defer:
      X509_free(cert)
      EVP_PKEY_free(pkey)

    if SSL_CTX_use_certificate(sslCtx, cert) != 1:
      raiseAssert "could not use certificate"

    if SSL_CTX_use_PrivateKey(sslCtx, pkey) != 1:
      raiseAssert "could not use private key"

    if SSL_CTX_check_private_key(sslCtx) != 1:
      raiseAssert "cant use private key with certificate"

  if (SSL_CTX_set1_sigalgs_list(sslCtx, "ed25519:ecdsa_secp256r1_sha256") != 1):
    raiseAssert "could not set supported algorithm list"

  if quicCtx.tlsConfig.certVerifier.isSome:
    SSL_CTX_set_custom_verify(
      sslCtx, SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, verifyCertificate
    )

  if quicCtx of ServerContext:
    SSL_CTX_set_alpn_select_cb(sslCtx, alpnSelectProtoCB, cast[pointer](quicCtx))
  else:
    if SSL_CTX_set_alpn_protos(
      sslCtx,
      cast[ptr uint8](quicCtx.tlsConfig.alpnWire.cstring),
      cast[cuint](quicCtx.tlsConfig.alpnWire.len),
    ) != 0:
      raiseAssert "can't set client alpn"

  discard SSL_CTX_set_min_proto_version(sslCtx, TLS1_3_VERSION)
  discard SSL_CTX_set_max_proto_version(sslCtx, TLS1_3_VERSION)

  quicCtx.sslCtx = sslCtx

proc getSSLCtx*(peer_ctx: pointer, sockaddr: ptr SockAddr): ptr SSL_CTX {.cdecl.} =
  let quicCtx = cast[QuicContext](peer_ctx)
  quicCtx.sslCtx

proc stop*(ctx: QuicContext) {.raises: [].} =
  ctx.tickTimeout.stop()
  lsquic_engine_destroy(ctx.engine)

proc close*(ctx: QuicContext, conn: QuicConnection) =
  if conn != nil and conn.lsquicConn != nil:
    lsquic_conn_close(conn.lsquicConn)
    ctx.processWhenReady()

proc abort*(ctx: QuicContext, conn: QuicConnection) =
  if conn != nil and conn.lsquicConn != nil:
    lsquic_conn_abort(conn.lsquicConn)
    ctx.processWhenReady()

method dial*(
    ctx: QuicContext,
    local: TransportAddress,
    remote: TransportAddress,
    connectedFut: Future[void],
    onClose: proc() {.gcsafe, raises: [].},
): Result[QuicConnection, string] {.base, gcsafe, raises: [].} =
  raiseAssert "dial not implemented"

proc makeStream*(ctx: QuicContext, quicConn: QuicConnection) {.raises: [].} =
  debug "Creating stream"
  if quicConn == nil or quicConn.lsquicConn == nil:
    debug "Cannot create stream: connection is nil"
    return
  lsquic_conn_make_stream(quicConn.lsquicConn)

proc onNewStream*(
    stream_if_ctx: pointer, stream: ptr lsquic_stream_t
): ptr lsquic_stream_ctx_t {.cdecl.} =
  debug "New stream created"
  let conn = lsquic_stream_conn(stream)
  let conn_ctx = lsquic_conn_get_ctx(conn)
  if conn_ctx.isNil:
    debug "conn_ctx is nil in onNewStream"
    return nil

  let quicConn = cast[QuicConnection](conn_ctx)
  let stream_id = lsquic_stream_id(stream).int
  let isLocal =
    if quicConn.isOutgoing:
      (stream_id and 1) == 0
    else:
      (stream_id and 1) == 1

  let streamCtx =
    if isLocal:
      let s = quicConn.popPendingStream(stream).valueOr:
        return
      # Whoever opens the stream writes first
      discard lsquic_stream_wantread(stream, 0)
      discard lsquic_stream_wantwrite(stream, 1)
      s
    else:
      let s = Stream.new(stream)
      quicConn.incoming.putNoWait(s)
      # Whoever opens the stream reads first
      discard lsquic_stream_wantread(stream, 1)
      discard lsquic_stream_wantwrite(stream, 0)
      s

  return cast[ptr lsquic_stream_ctx_t](streamCtx)

proc certificates*(
    ctx: QuicContext, conn: QuicConnection
): seq[seq[byte]] {.raises: [].} =
  conn.certChain
