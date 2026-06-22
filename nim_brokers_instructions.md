# Working with `nim-brokers`

> Drop-in CLAUDE.md addon for any project that depends on the `brokers` nimble
> package. Type-safe, decoupled messaging on top of **chronos** + **results**.
> All public APIs are exception-free: errors ride `Result[T, string]`, never raises.

## Mental model

Three macros, each declares a **broker type** and generates its full API. The
type *is* the channel — you call class-method-style on the typedesc: `T.emit`,
`T.request`, `T.listen`, `T.setProvider`. No instances, no singletons to wire.

| Macro | Pattern | Producer side | Consumer side |
|-------|---------|---------------|---------------|
| `EventBroker` | pub/sub, many→many, fire-and-forget | `T.emit(...)` | `T.listen(handler)` |
| `RequestBroker` | request/response, **single** provider | `T.setProvider(handler)` | `T.request(...)` |
| `MultiRequestBroker` | request/response, **many** providers, fan-out | `T.setProvider(handler)` (N×) | `T.request(...)` |

`(mt)` suffix → multi-thread variant (cross-thread dispatch). `(sync)` on
RequestBroker → blocking, non-async. `(API)` → FFI shared-library surface.

Import only what you use:
```nim
import brokers/event_broker
import brokers/request_broker
import brokers/multi_request_broker
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

- `emit` is **sync** here (single-thread): snapshots listeners, `asyncSpawn`s
  each. It does not await delivery — `await sleepAsync(0)` or yield to flush in tests.
- Handlers MUST be `{.async: (raises: []).}`. Swallow your own exceptions.
- `dropListener`/`dropAllListeners` are `async` and **cancel** in-flight handlers
  before returning — safe teardown point before releasing resources.

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

Add `(mt)`. Same surface, but **`emit` becomes async** (cross-thread dispatch
via `Channel[T]`). Build with `--threads:on`.

```nim
EventBroker(mt):
  type Job = object
    id*: int

# from any thread:
proc worker() {.thread.} =
  waitFor Job.emit(Job(id: 1))     # mt emit is async — await / waitFor it
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
| Same pattern across OS threads | add `(mt)`, `--threads:on`, await `emit` |
| Multiple isolated instances | pass a `BrokerContext` first arg |
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

Add `(API)` to `RequestBroker`/`EventBroker`. Same declaration syntax — it
additionally generates a fixed C ABI and typed foreign wrappers. Wire format is
CBOR; wrappers carry the typed surface. Build with `-d:BrokerFfiApi --threads:on
--app:lib`.

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
      await DeviceStatusChanged.emit(ctx,   # API emit is async — await it
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

What you get — a fixed **11-function C ABI** per library: `_version`,
`_initialize` (once per process), `_createContext` (per instance), `_shutdown(ctx)`,
`_allocBuffer`, `_freeBuffer`, `_call`, `_subscribe`, `_unsubscribe`, `_listApis`,
`_getSchema`. `<lib>.h` (C) and `<lib>.hpp` (C++) are always emitted.

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
