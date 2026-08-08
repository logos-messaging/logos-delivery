# Browser edge node (wasm)

`library/edge/edge_lib.nim` builds to a WebAssembly module exposing a small C ABI
(`edge_new`, `edge_lightpush_publish`, `edge_filter_subscribe`, `edge_store_query`,
`edge_stop`, `ffi_poll`). Build it with `scripts/build_edge_wasm.sh`; the output lands in
`build/wasm/edge.{js,wasm}`.

The build is `--threads:off`, so it uses the two overrides in `wasm-deps/` (`ffi` and
`brokers`), wired in `config.nims` under `-d:emscripten`, plus `wasm-deps/edge_builders.nim`
in place of `libp2p/builders`. See `scripts/gen_edge_builders.py`.

## Driving the event loop: `ffi_poll()`

There is no worker thread in the browser build. The host owns the loop and must call
`ffi_poll()`, which advances chronos by **exactly one iteration**.

That makes the host's poll *rate* a hard ceiling on how fast libp2p can complete anything.
A handshake is not one iteration — multistream, noise, yamux, identify and the waku
metadata exchange are thousands of small reads and writes, each needing a poll to progress.

**Do not do this:**

```js
setInterval(() => M._ffi_poll(), 1);   // ~250 polls/s — far too slow
```

`setInterval` is clamped to ~4ms by every browser (and throttled to 1/s in a background
tab), and it runs the body *once* per tick. Measured against a wakunode2 on localhost:

| pump                       | identify | filter subscribe                        |
| -------------------------- | -------- | --------------------------------------- |
| `setInterval(poll, 1)`     | ~12.7 s  | never completes                         |
| burst (below)              | ~1.0 s   | succeeds, ~1 s end to end               |

With the slow pump the node gives up first — it dials `/vac/waku/metadata/1.0.0` on the
edge, times out, and disconnects with `waku metatdata request failed: read failed: Stream
Closed!`, which kills the in-flight subscribe. The symptom looks like a filter bug and is
not one. The `waku metadata ... Stream EOF!` line in the browser console is the same
starvation seen from the other side.

**Do this instead** — burst while a request is outstanding, idle on a throttled timer so
an idle node is not a CPU spinner:

```js
const pump = (() => {
  const BURST_MS = 4, IDLE_BATCH = 64, IDLE_TICK_MS = 4;
  const chan = new MessageChannel();          // not clamped, unlike setTimeout/Interval
  let inFlight = 0, queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    if (inFlight > 0) chan.port2.postMessage(0); else setTimeout(tick, IDLE_TICK_MS);
  };
  const tick = () => {
    queued = false;
    if (inFlight > 0) {
      const t0 = performance.now();
      do { M._ffi_poll(); } while (performance.now() - t0 < BURST_MS);
    } else {
      for (let i = 0; i < IDLE_BATCH; i++) M._ffi_poll();
    }
    schedule();
  };
  chan.port1.onmessage = tick;
  schedule();
  return { enter: () => { inFlight++; schedule(); }, leave: () => { inFlight--; } };
})();
```

Call `pump.enter()` when submitting a request and `pump.leave()` from its callback — the
one place every request already passes through. The idle batch still has to be generous:
it is what services timers, keepalives and inbound filter pushes. 64 polls per 4ms tick
holds a subscription open indefinitely (verified over several minutes).

`build/wasm/chat_demo_local.html` is the reference harness and uses exactly this pump.

## Reproducing against a local node

```sh
wakunode2 --cluster-id=16 --shard=32 --relay=true --lightpush=true --filter=true \
          --store=true --websocket-support=true --websocket-port=8401 --tcp-port=60401 \
          --nat=extip:<your-lan-ip> --nodekey=<64 hex chars>
```

Point `SERVICE` in the demo at the `/ws` multiaddr the node logs under `Listening on`, serve
`build/wasm` over HTTP, and open the page. A lone node answers lightpush with `No peers for
topic, skipping publish` — that is the node having no relay mesh, not an edge failure.
