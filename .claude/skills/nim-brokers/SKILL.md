---
name: nim-brokers
description: Reference for writing code against the nim-brokers (`brokers`) nimble package — EventBroker, RequestBroker, MultiRequestBroker, SignalBroker, body sugars (listenIt, provideIt, reprovideIt, onSignalIt), bind* sugar, BrokerContext scoping, (mt) multi-thread variants, the (API) FFI shared-library surface, and BrokerInterface/BrokerImplement. Use when declaring brokers, registering listeners/providers/handlers, emitting or requesting, or exposing brokers to C/C++/Python/Rust/Go.
---

# Working with `nim-brokers`

> Agent skill for any project that depends on the `brokers` nimble package.
> For auto-discovery, copy this file into the consuming project as
> `.claude/skills/nim-brokers/SKILL.md` (or reference it from CLAUDE.md/AGENTS.md).
> Type-safe, decoupled messaging on top of **chronos** + **results**.
> All public APIs are exception-free: errors ride `Result[T, string]`, never raises.

## Mental model

Four macros, each declares a **broker type** and generates its full API. The
type *is* the channel — you call class-method-style on the typedesc: `T.emit`,
`T.request`, `T.listen`, `T.setProvider`. No instances, no singletons to wire.

| Macro | Pattern | Producer side | Consumer side |
|-------|---------|---------------|---------------|
| `EventBroker` | pub/sub, many→many, fire-and-forget | `T.emit(...)` | `T.listen(handler)` |
| `RequestBroker` | request/response, **single** provider | `T.setProvider(handler)` | `T.request(...)` |
| `MultiRequestBroker` | request/response, **many** providers, fan-out | `T.setProvider(handler)` (N×) | `T.request(...)` |
| `SignalBroker` | one-way notification, **single** handler, no reply | `T.signal(...)` | `T.onSignal(handler)` |

`(mt)` suffix → multi-thread variant (cross-thread dispatch). `(sync)` on
RequestBroker → blocking, non-async. `(API)` → FFI shared-library surface.

Any provider/handler that is a **class method** (`self.foo`) can be installed
with the `bind*` / `rebind*` sugar instead of a hand-written forwarding closure —
see "Binding class-method providers" below. For inline bodies, each registration
verb also has a **body-sugar form** (`listenIt`, `provideIt` / `reprovideIt`,
`onSignalIt`) that takes a block instead of a lambda — see the per-broker sections.

Import only what you use:
```nim
import brokers/event_broker
import brokers/request_broker
import brokers/multi_request_broker
import brokers/signal_broker
import brokers/broker_context   # only if you need explicit contexts
```

---

## EventBroker — pub/sub

```nim
import chronos, brokers/event_broker

EventBroker:
  type UserLoggedIn = object
    userId*: int
    name*: string

# listen returns Result[ListenerHandle, string]; keep the handle to drop later
let h = UserLoggedIn.listen(
  proc(evt: UserLoggedIn): Future[void] {.async: (raises: []).} =
    info "login", id = evt.userId
)

UserLoggedIn.emit(UserLoggedIn(userId: 7, name: "zoli"))   # by value
UserLoggedIn.emit(userId = 7, name = "zoli")               # by fields (inline-object only)

await UserLoggedIn.dropListener(h.get())   # drop one — cancels its in-flight work
await UserLoggedIn.dropAllListeners()      # drop all for this context
```

- `emit` is **sync `void`** in *every* lane (single-thread, `(mt)`, `(API)`):
  snapshots listeners, `asyncSpawn`s each. It does not await delivery —
  `await sleepAsync(0)` or yield to flush in tests. Never `await`/`waitFor` an emit.
- Handlers MUST be `{.async: (raises: []).}`. Swallow your own exceptions.
- `dropListener`/`dropAllListeners` are **`async` (`Future[void]`) in every lane**
  — `await` them (or `discard`/`waitFor` in sync/`{.thread.}` contexts). Single-thread
  cancels in-flight handlers before returning; MT/API bodies are suspension-free.

### `listenIt` — listener body sugar (all lanes)
```nim
# The block IS the listener body; the event value is injected as `it`.
# Returns listen's Result[<T>Listener, string] — keep it to drop later.
let h2 = UserLoggedIn.listenIt:
  echo "login: ", it.name, " (#", it.userId, ")"

let h3 = UserLoggedIn.listenIt(myCtx):   # ctx-scoped form; body may await
  await sleepAsync(chronos.milliseconds(1))
  echo "scoped: ", it.name
```
- `raises: []` is enforced as for a hand-written listener; `void` event types
  inject nothing (the block is just the body).

### Payload variants
```nim
EventBroker:
  type Tick = void              # payload-less signal: Tick.emit() / listen(proc(): Future[void]...)
EventBroker:
  type Score = int              # native/alias/external types auto-wrapped in distinct
EventBroker:
  type Blob = ref object        # ref payloads fine
    data*: seq[byte]
```

---

## RequestBroker — single provider request/response

Two declaration styles. **Coupled** (named `type` + `proc`) and **proc-sugar**
(payload decoupled, broker named after the Capitalized verb).

```nim
import chronos, brokers/request_broker

# Coupled: broker name == type name == request() return payload
RequestBroker:
  type FetchUser = object
    name*: string
  proc signature*(id: int): Future[Result[FetchUser, string]] {.async.}

FetchUser.setProvider(
  proc(id: int): Future[Result[FetchUser, string]] {.async.} =
    ok(FetchUser(name: "u" & $id))
).isOk()

let r = await FetchUser.request(42)        # Result[FetchUser, string]
FetchUser.clearProvider()
```

```nim
# Proc-sugar: broker = Capitalized verb, request() returns the RAW payload
RequestBroker:
  proc getVersion(): Future[Result[string, string]] {.async.}   # -> broker `GetVersion`

GetVersion.setProvider(
  proc(): Future[Result[string, string]] {.async.} = ok("1.2.3")).get()
let v = await GetVersion.request()         # r.value is plain string, no unwrap
```

Rules & behaviors:
- **One provider per signature.** A second `setProvider` returns `err(...)` (no
  silent override). `clearProvider()` first to swap.
- Two signature slots coexist: zero-arg and arg-based (overload by arity).
- Provider exceptions are caught → `err(<msg>)`. Unset provider → `err(...)`.
- `isProvided()` checks registration. `T.request` is `async` here.

### `provideIt` / `reprovideIt` — provider body sugar (all lanes)
```nim
# The block is the provider's REAL proc body — the declared signature arg
# names (`id` here) are injected; return / result= / trailing expression work.
discard FetchUser.provideIt:          # -> setProvider (keeps "already set" guard)
  if id < 0:
    return err("bad id: " & $id)
  return ok(FetchUser(name: "u" & $id))

discard FetchUser.reprovideIt:        # -> replaceProvider (swap, no guard)
  ok(FetchUser(name: "v2-u" & $id))   # trailing expression works too
```
- A body that could fall through without producing a value is a **compile
  error** (it would silently answer `err("")`) — e.g. a bare `echo` body, or an
  `if` without `else` where only one branch returns.
- Dual-slot brokers name the slots explicitly: `provideIt` / `reprovideIt` for
  the args slot, `provideItNoArgs` / `reprovideItNoArgs` for the zero-arg slot.
- Sync mode: same sugar, body cannot `await`. Ctx-form: `T.provideIt(ctx): body`.

### Sync mode — no event loop needed
```nim
RequestBroker(sync):
  proc getId(): Result[int, string]              # note: no Future, no {.async.}
GetId.setProvider(proc(): Result[int, string] = ok(42)).isOk()
let id = GetId.request()                          # blocking, returns Result directly
```

### void payload (action with no return value)
```nim
RequestBroker:
  proc doReset(force: bool): Future[Result[void, string]] {.async.}
DoReset.setProvider(proc(force: bool): Future[Result[void, string]] {.async.} =
  if force: ok() else: err("need force")).isOk()
```

---

## MultiRequestBroker — fan-out to many providers

Async only. `request()` calls **all** providers via `allFinished`, returns
`Result[seq[Payload], string]`. Any provider failing fails the whole request.

```nim
import chronos, brokers/multi_request_broker

MultiRequestBroker:
  type Quote = object
    price*: int
  proc signature*(sym: string): Future[Result[Quote, string]] {.async.}

discard Quote.setProvider(proc(sym: string): Future[Result[Quote, string]] {.async.} =
  ok(Quote(price: 100)))
discard Quote.setProvider(proc(sym: string): Future[Result[Quote, string]] {.async.} =
  ok(Quote(price: 101)))

let all = await Quote.request("BTC")    # all.get() is seq[Quote], len == 2
Quote.removeProvider(handle.get())      # remove one (handle from setProvider)
Quote.clearProviders()                  # remove all
```

- No providers registered → `ok(@[])` (empty, not error).
- Identical handler refs deduplicated on registration.
- `setProvider` returns `Result[ProviderHandle, string]`; capture it for `removeProvider`.

### `provideIt` — provider body sugar (adds, not replaces)
```nim
# Same body sugar as RequestBroker, but every provideIt ADDS a provider —
# there is NO reprovideIt (no replace verb), and the generated closure is a
# fresh reference, so it never dedups. Returns setProvider's handle.
let h1 = Quote.provideIt:
  ok(Quote(price: 100))
let h2 = Quote.provideIt:            # a second provider — NOT a replacement
  if sym.len == 0:
    return err("empty symbol")
  return ok(Quote(price: 101))

Quote.removeProvider(h1.get())       # drop just one by its handle
```
- Dual-slot brokers: `provideIt` = args slot, `provideItNoArgs` = zero-arg slot.
- Same fall-through compile check as RequestBroker's `provideIt`.

---

## SignalBroker — one-way notification, single handler

Fire-and-forget into a module: an **inverted EventBroker** (single handler, no
reply path). `signal()` is a **plain (non-async) proc** returning
`Result[void, string]`; it does not tell you whether the handler *succeeded* —
only whether it was **accepted**. Handler exceptions are swallowed (chronicles
`warn`). For delivery confirmation, use `RequestBroker` with a `void` response.

```nim
import chronos, brokers/signal_broker

SignalBroker:
  type IngestSample = object
    deviceId*: string
    value*: float64

# ONE handler (a second onSignal returns err). Handler is async, raises: [].
discard IngestSample.onSignal(
  proc(s: IngestSample) {.async: (raises: []).} =
    info "sample", dev = s.deviceId, v = s.value)

let r = IngestSample.signal(IngestSample(deviceId: "d1", value: 0.5))  # by value
discard IngestSample.signal(deviceId = "d2", value = 1.25)             # by fields
# r: Result[void, string]
#   ok()  = ACCEPTED (a handler exists + queue had room) — NOT "handled"
#   err() = "no signal handler installed" | "queue full"

await IngestSample.dropSignalHandler()   # async Future[void] — await it
```

### `onSignalIt` — handler body sugar (all lanes)
```nim
# Same as listenIt, for the single signal handler: the block is the handler
# body, the signal value is injected as `it`. onSignal's duplicate guard and
# Result return are unchanged.
discard IngestSample.onSignalIt:
  echo it.deviceId, " = ", it.value

discard Wakeup.onSignalIt: echo "tick"   # void payload: nothing injected
```

- `signal()` is **sync**, never `await` it. `dropSignalHandler()` is **async**.
- `type Foo = void` → payload-less pulse: `Foo.signal()` / `onSignal(proc() ...)`.
- Mock/replace trio (owning-thread only on `(mt)`): `replaceSignalHandler`,
  `getCurrentSignalHandler`, `withMockSignalHandler(ctx, mock): body`.
- `(mt)` and `(API)` variants mirror the other brokers (one handler per context).

---

## Binding class-method providers — `bind*` / `rebind*` (v3.1)

Nim has no bound-method values (`self.send` is not a closure), so installing a
class method as a provider/handler normally needs a hand-written trampoline. The
`bind*` sugar synthesises it — **identical codegen, identical `self` capture**.
Passing a plain closure works too, so it is a strict superset of the typed verbs
(`setProvider` / `listen` / `onSignal` stay untouched).

```nim
# before — hand-written forwarding closure
MessagingSend.setProvider(self.brokerCtx,
  proc(e: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
    await self.send(e))

# after — the sugar generates exactly that trampoline
MessagingSend.bindProvider(self.brokerCtx, self.send)
```

| Broker | install sugar | replace sugar |
|--------|---------------|---------------|
| `RequestBroker` / `(mt)` | `bindProvider` | `rebindProvider` |
| `MultiRequestBroker` | `bindProvider` (additive) | — |
| `EventBroker` / `(mt)` | `bindListener` (returns the listen handle) | — |
| `SignalBroker` / `(mt)` | `bindSignalHandler` | `rebindSignalHandler` |

- Each verb has a **ctx-form** (`bindProvider(ctx, m)`) and a **no-ctx-form**
  (`bindProvider(m)` → thread-global context).
- Dual-slot RequestBrokers (zero-arg **and** arg signatures) disambiguate by
  arity automatically.
- Works on the `(API)` lane too — usable inside `setupProviders(ctx)`.

---

## BrokerContext — scoping / multi-instance

Every API takes an **optional first `BrokerContext` arg**. Omit it → the
thread-global context (`DefaultBrokerContext`). Use contexts to run independent
broker instances (per component, per test, per thread).

```nim
import brokers/broker_context

let ctx = NewBrokerContext()                       # globally-unique id (atomic)

discard MyEvent.listen(ctx, handler)
MyEvent.emit(ctx, payload)
FetchUser.setProvider(ctx, provider)
let r = await FetchUser.request(ctx, 42)
await MyEvent.dropAllListeners(ctx)
```

Thread setup helpers (callable before the event loop starts):
| Call | Use |
|------|-----|
| `setThreadBrokerContext(ctx)` | adopt a context created elsewhere as this thread's global |
| `initThreadBrokerContext(): BrokerContext` | create + set as thread-global in one call |
| `threadGlobalBrokerContext()` | read current thread global (lock-free) |

Async scoped swap (needs chronos loop): `lockGlobalBrokerContext` /
`lockNewGlobalBrokerContext` templates.

---

## Multi-thread variants `(mt)`

Add `(mt)`. **Identical call surface** — `emit` stays sync `void` and `drop*`
stay async (`Future[void]`), so the same source compiles with or without the
tag. Cross-thread dispatch is handled under the hood. Build with `--threads:on`.

```nim
EventBroker(mt):
  type Job = object
    id*: int

# from any thread:
proc worker() {.thread.} =
  Job.emit(Job(id: 1))             # emit is sync void — same as single-thread
```

- Same-thread calls take a direct fast path; cross-thread go through a per-bucket
  channel drained by one dispatch coroutine. fd cost is **O(threads)**, not per-broker.
- A thread that listens must keep its event loop alive (the broker dispatches on it).
- MT brokers accept capacity kwargs: `EventBroker(mt, queueDepth = ..., slabCapacity = ...,
  maxPayloadBytes = ..., preset = "...")`. Omit for defaults.

---

## Decision guide

| You want… | Use |
|-----------|-----|
| Notify N listeners, don't care about replies | `EventBroker` |
| Ask one authority for an answer | `RequestBroker` |
| Blocking call, no async context | `RequestBroker(sync)` |
| Ask everyone, aggregate replies | `MultiRequestBroker` |
| One-way notify a single handler, no reply | `SignalBroker` |
| Same pattern across OS threads | add `(mt)`, `--threads:on` (call surface unchanged) |
| Multiple isolated instances | pass a `BrokerContext` first arg |
| Install a class method (`self.foo`) as provider/handler | `bind*` / `rebind*` sugar |
| Register an inline body without lambda boilerplate | `listenIt` / `provideIt` / `reprovideIt` / `onSignalIt` |
| Expose to C/C++/Python/Rust/Go | `(API)` + `registerBrokerLibrary` (see AGENTS.md) |

## Gotchas

- Handlers/providers are `raises: []` — never let an exception escape; return `err()`.
- `setProvider` on a RequestBroker that already has one **fails** — clear first.
- Single-thread `emit` returns immediately; await a yield before asserting in tests.
- A non-`object`/`ref object` broker type is auto-wrapped in `distinct`; construct
  with `T(value)` and read with the base-type conversion.
- Keep all interaction with one context on one thread (single-thread brokers are
  thread-local); cross-thread requires the `(mt)` variant.

---

## FFI API `(API)` — expose brokers as a C/C++/Python/Rust/Go shared library

Add `(API)` to `RequestBroker` / `EventBroker` / `SignalBroker`. Same declaration
syntax — it additionally generates a fixed C ABI and typed foreign wrappers. Wire
format is CBOR; wrappers carry the typed surface. Build with `-d:BrokerFfiApi
--threads:on --app:lib`. (`SignalBroker(API)` rides `_call` one-way — enqueue
only, no response slot; `_callAsync` rejects it with `ApiStatusOneWay`.)

```nim
{.push raises: [].}
import brokers/[event_broker, request_broker, broker_context, api_library]

# Plain Nim object types used in signatures are AUTO-registered — no annotation.
type DeviceInfo* = object
  deviceId*: int64
  name*: string
  online*: bool

RequestBroker(API):
  type GetDevice = object        # broker name == type name == response payload
    deviceId*: int64
    name*: string
  proc signature*(deviceId: int64): Future[Result[GetDevice, string]] {.async.}

EventBroker(API):
  type DeviceStatusChanged = object
    deviceId*: int64
    online*: bool
    timestampMs*: int64
```

Providers + event emission live in one proc named **`setupProviders`** (the
generated runtime calls it on the processing thread during `createContext`):

```nim
proc setupProviders(ctx: BrokerContext): Result[void, string] =
  let r = GetDevice.setProvider(ctx,        # always pass the ctx the runtime gives you
    proc(deviceId: int64): Future[Result[GetDevice, string]] {.closure, async.} =
      DeviceStatusChanged.emit(ctx,         # emit is sync void (all lanes)
        DeviceStatusChanged(deviceId: deviceId, online: true, timestampMs: 0))
      ok(GetDevice(deviceId: deviceId, name: "u")))
  if r.isErr(): return err("register GetDevice: " & r.error())
  ok()

# MUST be the last declaration in the module:
registerBrokerLibrary:
  name: "mylib"                  # MUST match --nimMainPrefix and the .so basename
  version: "1.0.0"              # baked into <lib>_version() static string
  initializeRequest: InitializeRequest   # post-create config broker (optional)
  shutdownRequest: ShutdownRequest        # orderly teardown broker (optional)
{.pop.}
```

Build (name / `--nimMainPrefix` / `registerBrokerLibrary name` must all match):
```
nim c -d:BrokerFfiApi --threads:on --app:lib --path:. \
  --outdir:build --nimMainPrefix:mylib mylib.nim
```

What you get — a fixed **12-function C ABI** per library: `_version`,
`_initialize` (once per process), `_createContext` (per instance), `_shutdown(ctx)`,
`_allocBuffer`, `_freeBuffer`, `_call` (sync round-trip), `_callAsync`
(non-blocking, callback-completed), `_subscribe`, `_unsubscribe`, `_listApis`,
`_getSchema`. `<lib>.h` (C) and `<lib>.hpp` (C++) are always emitted. Wire format
is CBOR (the historical native C-ABI codegen was retired in 3.0.0).

| Flag | Emits | Notes |
|------|-------|-------|
| *(default)* | `<lib>.h`, `<lib>.hpp` | C + C++ always |
| `-d:BrokerFfiApiGenPy` | `<lib>.py` (cbor2) | next to the `.so` |
| `-d:BrokerFfiApiGenRust` | `<lib>_rs/` Cargo crate | ciborium + serde |
| `-d:BrokerFfiApiGenGo` | `<lib>_go/` Go module | fxamacker/cbor |

FFI rules:
- `registerBrokerLibrary` is a **no-op without `-d:BrokerFfiApi`** — no `when defined`
  guard needed; the normal in-process broker API still works.
- `(API)` brokers ride the MT lane, so they accept the same capacity kwargs as
  `(mt)`: `RequestBroker(API, queueDepth = .., slabCapacity = .., maxPayloadBytes = ..,
  preset = "..")`.
- `_createContext()` is readiness-synchronous: returns only after providers +
  listeners are installed and the event courier is live.
- Inspect generated Nim with `-d:brokerDebug` → `build/broker_debug/*.gen.nim`.

---

## BrokerInterface / BrokerImplement — hierarchical / OOP layer

An object-oriented facade over the brokers: an **interface** groups several
brokers behind one abstract type; an **implementation** provides per-instance
methods. Each instance gets its own `BrokerContext`, so two instances of the same
impl are fully isolated. Direct `instance.method()` calls **tunnel through broker
dispatch** (so provider mocks are honored — not a plain vtable call).

```nim
import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(IGreeter):
  EventBroker:
    type Greeted = object
      who: string
  RequestBroker:
    proc greet(name: string): Future[Result[string, string]] {.async.}
  RequestBroker:
    proc version(): Future[Result[string, string]] {.async.}

type GreeterImpl = ref object of IGreeter   # MUST be `ref object of <Interface>`
  prefix: string

BrokerImplement GreeterImpl of IGreeter:
  proc new(T: typedesc[GreeterImpl], prefix: string): GreeterImpl =
    GreeterImpl(prefix: prefix)             # optional ctor; create() calls it
  method greet(self: GreeterImpl, name: string): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)
  method version(self: GreeterImpl): Future[Result[string, string]] {.async.} =
    ok("v2")
```

Use it:
```nim
let g = GreeterImpl.create(prefix = "hi ")   # new() + wires providers under g.brokerCtx
echo (waitFor g.greet("sue")).value          # "hi sue" — tunnels through Greet broker

let base: IGreeter = g                       # virtual dispatch via the interface type
echo (waitFor base.greet("x")).value         # resolves to the override

# Each instance is isolated by its own context:
let a = GreeterImpl.create(prefix = "a:")
let b = GreeterImpl.create(prefix = "b:")
# a.brokerCtx != b.brokerCtx

g.close()        # clears THIS instance's providers + listeners; idempotent
```

Event facade (instance-scoped listen/emit — context is injected for you):
```nim
discard g.listen(Greeted,
  proc(ev: Greeted): Future[void] {.async: (raises: []), gcsafe.} = …)
g.emit(Greeted, Greeted(who: "bob"))
```

Factory / dependency injection (resolve an impl behind the interface):
```nim
IGreeter.provideFactory(
  proc(cfg: string): Result[IGreeter, string] =
    ok(GreeterImpl.create(prefix = cfg)))
let d = IGreeter.create("cfg:")              # Result[IGreeter, string]; last factory wins
```

Key points:
- The broker for `proc greet` is named **`Greet`** (Capitalized verb). Address it
  directly with the instance context: `Greet.request(g.brokerCtx, "bob")`,
  `Greet.clearProvider(g.brokerCtx)` (e.g. to install a mock).
- `Impl.create(args…)` = fresh context + `new` + provider wiring.
  `Impl.createUnderContext(ctx, args…)` wires under an externally-supplied context
  (the path the FFI runtime drives).
- `BrokerInterface(API, IName)` lowers the sub-brokers onto the MT/FFI lane so the
  whole interface can be exposed as a shared library; `BrokerImplement` is unchanged.
- Sub-instances returned from a method (factory pattern) share the parent's
  `classCtx` (routing) but get a distinct `instanceCtx` — see `classCtx()` /
  `instanceCtx()` accessors.
