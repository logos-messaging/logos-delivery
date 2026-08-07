## A dial-only nim-libp2p Transport backed by the browser's WebSocket API.
##
## In a browser/wasm sandbox there are no OS sockets, so the stock `WsTransport`
## (websock over chronos TCP) cannot run. This transport instead drives the
## host `WebSocket` object through an EM_JS bridge: the browser opens the socket
## and pumps events into wasm, while the libp2p upgrade (noise + muxer) runs in
## wasm over the resulting byte stream. Edge nodes only ever *dial* a service
## node's `/wss` multiaddr, so `accept`/listen are intentionally unsupported.
##
## Node 25+ exposes a global `WebSocket`, so the byte-bridge is testable under
## node as well as in the browser.

{.push raises: [].}

import std/[tables, strutils]
import results
import chronos, chronicles
import
  libp2p/transports/transport,
  libp2p/stream/connection,
  libp2p/stream/lpstream,
  libp2p/multiaddress,
  libp2p/multicodec,
  libp2p/peerid,
  libp2p/upgrademngrs/upgrade

logScope:
  topics = "libp2p ws-browser-transport"

# --- JS bridge ----------------------------------------------------------------
# EM_JS emits real C symbols (imported below). The browser owns the sockets in
# `Module.__ws`; events call back into the exported wasm hooks at the bottom.
{.emit: """/*INCLUDESECTION*/
#include <emscripten.h>
EM_JS(int, wsbridge_open, (char* urlPtr), {
  const url = UTF8ToString(urlPtr);
  const st = (Module.__ws = Module.__ws || { map: {}, next: 1 });
  const handle = st.next++;
  let ws;
  try { ws = new WebSocket(url); } catch (e) { return -1; }
  ws.binaryType = 'arraybuffer';
  st.map[handle] = ws;
  ws.onopen = () => Module._wsbridge_on_open(handle);
  ws.onclose = () => Module._wsbridge_on_close(handle);
  ws.onerror = () => Module._wsbridge_on_error(handle);
  ws.onmessage = (ev) => {
    const bytes = new Uint8Array(ev.data);
    const p = Module._malloc(bytes.length || 1);
    Module.HEAPU8.set(bytes, p);
    Module._wsbridge_on_message(handle, p, bytes.length);
    Module._free(p);
  };
  return handle;
});
EM_JS(void, wsbridge_send, (int handle, void* ptr, int len), {
  const ws = Module.__ws && Module.__ws.map[handle];
  if (ws && ws.readyState === 1) ws.send(Module.HEAPU8.slice(ptr, ptr + len));
});
EM_JS(void, wsbridge_close, (int handle), {
  const ws = Module.__ws && Module.__ws.map[handle];
  if (ws) { try { ws.close(); } catch (e) {} delete Module.__ws.map[handle]; }
});
""".}

proc wsbridge_open(url: cstring): cint {.importc, cdecl.}
proc wsbridge_send(handle: cint, p: pointer, len: cint) {.importc, cdecl.}
proc wsbridge_close(handle: cint) {.importc, cdecl.}

# --- Connection ---------------------------------------------------------------

type WsBrowserConnection = ref object of Connection
  handle: cint
  rbuf: seq[byte] # received-but-unread bytes
  rpos: int # read cursor into rbuf
  readFut: Future[void] # a reader parked waiting for bytes
  openFut: Future[void] # the dial parked waiting for onopen
  opened: bool
  hadError: bool

var gConns {.threadvar.}: Table[cint, WsBrowserConnection]
  ## handle -> connection, so the exported JS hooks can route events.
  ## Single-threaded (wasm): a plain global is safe.

method initStream*(s: WsBrowserConnection) =
  if s.objName.len == 0:
    s.objName = "WsBrowserConnection"
  procCall Connection(s).initStream()

proc awaitSignal(fut: Future[void]) {.async: (raises: [CancelledError]).} =
  ## These futures are only ever `complete()`d (never `fail()`ed), so the only
  ## real outcome besides completion is cancellation. Narrow the effect so the
  ## LPStream methods keep their declared `raises`.
  try:
    await fut
  except CancelledError as e:
    raise e
  except CatchableError:
    discard

proc wakeReader(c: WsBrowserConnection) =
  if c.readFut != nil and not c.readFut.finished():
    let f = c.readFut
    c.readFut = nil
    f.complete()

method readOnce*(
    s: WsBrowserConnection, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  while s.rpos >= s.rbuf.len and not s.isEof:
    s.readFut = newFuture[void]("wsbrowser.readOnce")
    await awaitSignal(s.readFut)
  if s.rpos >= s.rbuf.len and s.isEof:
    return 0 # EOF
  let avail = s.rbuf.len - s.rpos
  let n = min(avail, nbytes)
  if n > 0:
    copyMem(pbytes, addr s.rbuf[s.rpos], n)
    s.rpos += n
  if s.rpos >= s.rbuf.len:
    s.rbuf.setLen(0)
    s.rpos = 0
  return n

method write*(
    s: WsBrowserConnection, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  ## `sink` is load-bearing: LPStream.write declares `msg: sink seq[byte]` as of
  ## libp2p 2.0.0. Declaring plain `seq[byte]` here compiles fine but is a
  ## DIFFERENT signature, so this stops overriding and every write dispatches to
  ## the base method -- `raiseAssert("[LPStream.write] abstract method not
  ## implemented!")`. The symptom is silent: the WebSocket opens, no byte is ever
  ## written, and the dial hangs forever with nothing logged on either side.
  if s.isEof:
    raise newLPStreamEOFError()
  if msg.len > 0:
    wsbridge_send(s.handle, unsafeAddr msg[0], msg.len.cint)

method closeImpl*(s: WsBrowserConnection): Future[void] {.async: (raises: []).} =
  wsbridge_close(s.handle)
  s.isEof = true
  gConns.del(s.handle)
  s.wakeReader()
  await procCall Connection(s).closeImpl()

# --- JS event hooks (exported; called from the EM_JS handlers) ----------------

proc wsbridge_on_open(handle: cint) {.exportc, cdecl.} =
  let c = gConns.getOrDefault(handle)
  if c.isNil:
    return
  c.opened = true
  if c.openFut != nil and not c.openFut.finished():
    let f = c.openFut
    c.openFut = nil
    f.complete()

proc wsbridge_on_message(handle: cint, data: ptr byte, len: cint) {.exportc, cdecl.} =
  let c = gConns.getOrDefault(handle)
  if c.isNil or len <= 0:
    return
  let start = c.rbuf.len
  c.rbuf.setLen(start + len.int)
  copyMem(addr c.rbuf[start], data, len.int)
  c.wakeReader()

proc wsbridge_on_close(handle: cint) {.exportc, cdecl.} =
  let c = gConns.getOrDefault(handle)
  if c.isNil:
    return
  c.isEof = true
  # Unblock a pending dial that never opened.
  if c.openFut != nil and not c.openFut.finished():
    let f = c.openFut
    c.openFut = nil
    f.complete()
  c.wakeReader()

proc wsbridge_on_error(handle: cint) {.exportc, cdecl.} =
  let c = gConns.getOrDefault(handle)
  if c.isNil:
    return
  c.hadError = true
  c.isEof = true
  if c.openFut != nil and not c.openFut.finished():
    let f = c.openFut
    c.openFut = nil
    f.complete()
  c.wakeReader()

# --- Transport ----------------------------------------------------------------

type WsBrowserTransport* = ref object of Transport

proc new*(T: type WsBrowserTransport, upgrade: Upgrade): T =
  let t = T(upgrader: upgrade)
  t.initialize()
  t

proc toWsUrl(address: MultiAddress, hostOverride: string): Result[string, string] =
  ## Build a ws(s):// URL from a /dns4|ip4|.../tcp/<port>/ws|wss[/tls] multiaddr.
  ## `hostOverride` (the original DNS hostname the dialer resolved) wins over the
  ## multiaddr host, which libp2p may have rewritten to a placeholder IP — the
  ## browser must connect to the real hostname for the wss TLS cert to validate.
  var host, port = ""
  var secure = false
  let parts = ($address).split('/')
  var i = 1
  while i < parts.len:
    case parts[i]
    of "dns4", "dns6", "dns", "dnsaddr", "ip4", "ip6":
      if i + 1 < parts.len:
        host = parts[i + 1]
      i += 2
    of "tcp":
      if i + 1 < parts.len:
        port = parts[i + 1]
      i += 2
    of "wss":
      secure = true
      i += 1
    of "tls":
      secure = true
      i += 1
    of "ws":
      i += 1
    else:
      i += 1
  if hostOverride.len > 0:
    host = hostOverride
  if host.len == 0 or port.len == 0:
    return err("multiaddr is not a ws endpoint: " & $address)
  let scheme = if secure: "wss" else: "ws"
  ok(scheme & "://" & host & ":" & port & "/")

method handles*(self: WsBrowserTransport, address: MultiAddress): bool {.raises: [].} =
  if not procCall Transport(self).handles(address):
    return false
  let protos = address.protocols.valueOr:
    return false
  for p in protos:
    if p == multiCodec("ws") or p == multiCodec("wss"):
      return true
  false

method dial*(
    self: WsBrowserTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  let url = toWsUrl(address, hostname).valueOr:
    raise (ref transport.TransportDialError)(msg: error)
  trace "ws-browser dialing", url
  let handle = wsbridge_open(url.cstring)
  if handle < 0:
    raise (ref transport.TransportDialError)(msg: "WebSocket construction failed: " & url)

  let conn = WsBrowserConnection(handle: handle, dir: Direction.Out)
  conn.observedAddr = Opt.some(address)
  conn.initStream()
  gConns[handle] = conn

  conn.openFut = newFuture[void]("wsbrowser.dial")
  await awaitSignal(conn.openFut)
  if conn.hadError or conn.isEof:
    gConns.del(handle)
    raise (ref transport.TransportDialError)(msg: "WebSocket failed to open: " & url)
  trace "ws-browser connected", url
  return conn

method accept*(
    self: WsBrowserTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  raise (ref transport.TransportError)(
    msg: "ws-browser transport is dial-only (no accept in the browser)"
  )
