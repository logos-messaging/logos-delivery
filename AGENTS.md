# AGENTS.md - AI Coding Context

This file provides essential context for LLMs assisting with Logos Messaging development.

## Project Identity

Logos Messaging is designed as a shared public network for generalized messaging, not application-specific infrastructure.

This project is a Nim implementation of a libp2p protocol suite for private, censorship-resistant P2P messaging. It targets resource-restricted devices and privacy-preserving communication.

Logos Messaging was formerly known as Waku. Waku-related terminology remains within the codebase for historical reasons.

### Design Philosophy

Key architectural decisions:

Resource-restricted first: Protocols differentiate between full nodes (relay) and light clients (filter, lightpush, store). Light clients can participate without maintaining full message history or relay capabilities. This explains the client/server split in protocol implementations.

Privacy through unlinkability: RLN (Rate Limiting Nullifier) provides DoS protection while preserving sender anonymity. Messages are routed through pubsub topics with automatic content-topic-based sharding (shard count is configurable; generation-zero defaults to 8 shards on cluster 0). Code prioritizes metadata privacy alongside content encryption.

Scalability via sharding: The network uses automatic content-topic-based sharding to distribute traffic. This is why you'll see sharding logic throughout the codebase and why pubsub topic selection is protocol-level, not application-level.

See [documentation](https://docs.waku.org/learn/) for architectural details.

### Core Protocols
- Relay: Pub/sub message routing using GossipSub
- Store: Historical message retrieval and persistence
- Filter: Lightweight message filtering for resource-restricted clients
- Lightpush: Lightweight message publishing for clients
- Peer Exchange: Peer discovery mechanism
- RLN Relay: Rate limiting nullifier for spam protection
- Metadata: Cluster and shard metadata exchange between peers
- Mix: Mixnet protocol for enhanced privacy through onion routing
- Rendezvous: Alternative peer discovery mechanism

### Key Terminology
- ENR (Ethereum Node Record): Node identity and capability advertisement
- Multiaddr: libp2p addressing format (e.g., `/ip4/127.0.0.1/tcp/60000/p2p/16Uiu2...`)
- PubsubTopic: Gossipsub topic for message routing (shard-based, e.g., `/waku/2/rs/<cluster-id>/<shard-id>`; the default is `/waku/2/rs/0/0`)
  - cluster-id: network id
  - shard-id: shard differentiator inside the network - drivers mesh forming.
    - autosharding: network supports n (configured) shards [0..n-1], shard derived from ContentTopic
- ContentTopic: Application-level message categorization (e.g., `/my-app/1/chat/proto`)
- Sharding: Partitioning network traffic across topics (static or auto-sharding)
- RLN (Rate Limiting Nullifier): Zero-knowledge proof system for spam prevention

### Specifications
All specs are at [rfc.vac.dev/waku](https://rfc.vac.dev/waku). RFCs use `WAKU2-XXX` format (not legacy `WAKU-XXX`).

## Architecture

### Protocol Module Pattern
Each protocol typically follows this structure:
```
waku_<protocol>/
├── protocol.nim       # Main protocol type and handler logic
├── client.nim         # Client-side API
├── rpc.nim           # RPC message types
├── rpc_codec.nim     # Protobuf encoding/decoding
├── common.nim        # Shared types and constants
└── protocol_metrics.nim  # Prometheus metrics
```

### WakuNode Architecture
- WakuNode (`waku/node/waku_node.nim`) is the central orchestrator
- Protocols are "mounted" onto the node's switch (libp2p component)
- PeerManager handles peer selection and connection management
- Switch provides libp2p transport, security, and multiplexing

Example protocol type definition:
```nim
type WakuFilter* = ref object of LPProtocol
  subscriptions*: FilterSubscriptions
  peerManager: PeerManager
  messageCache: TimedCache[string]
```

## Development Essentials

### Build Requirements
- Nim 2.x (check `waku.nimble` for minimum version)
- Rust toolchain (required for RLN dependencies)
- Build system: Make driven by Nimble (dependencies pinned in `nimble.lock`)

### Build System
The project uses a Makefile that drives Nimble. Dependencies are resolved from
`nimble.lock` into a local `nimbledeps/` directory (tracked by the
`NIMBLEDEPS_STAMP` target).
```bash
# Initial build (resolves Nimble deps automatically)
make wakunode2

# Build with custom flags
make wakunode2 NIMFLAGS="-d:chronicles_log_level=DEBUG"
```

Note: The build uses `--mm:refc` memory management (passed automatically by the Nimble tasks in `waku.nimble`). Only relevant if compiling outside the standard build system.

### Common Make Targets
```bash
make wakunode2          # Build main node binary
make test               # Run all tests
make testcommon         # Run common tests only
make libwaku            # Build the legacy C library (libwaku)
make liblogosdelivery. # Build actual C FFI library
make chat2              # Build chat example
make install-nph        # Install git hook for auto-formatting
```

### Testing
```bash
# Run all tests
make test

# Run specific test file
make test tests/test_waku_enr.nim

# Run specific test case from file
make test tests/test_waku_enr.nim "check capabilities support"

# Build and run test separately (for development iteration)
make test tests/test_waku_enr.nim
```

Test structure uses `testutils/unittests`:
```nim
import testutils/unittests

suite "Waku ENR - Capabilities":
  test "check capabilities support":
    ## Given
    let bitfield: CapabilitiesBitfield = 0b0000_1101u8

    ## Then
    check:
      bitfield.supportsCapability(Capabilities.Relay)
      not bitfield.supportsCapability(Capabilities.Store)
```

### Code Formatting
Mandatory: All code must be formatted with `nph` (installed via `make build-nph`, which fetches a pinned `nph` version with Nimble)
```bash
# Format specific file
make nph/waku/waku_core.nim

# Install git pre-commit hook (auto-formats on commit)
make install-nph
```
The nph formatter handles all formatting details automatically, especially with the pre-commit hook installed. Focus on semantic correctness.

### Logging
Uses `chronicles` library with compile-time configuration:
```nim
import chronicles

logScope:
  topics = "waku lightpush"

info "handling request", peerId = peerId, topic = pubsubTopic
error "request failed", error = msg
```

Compile with log level:
```bash
nim c -d:chronicles_log_level=TRACE myfile.nim
```

## Code Conventions

Common pitfalls:
- Always handle Result types explicitly
- Avoid global mutable state: Pass state through parameters
- Keep functions focused: Under 50 lines when possible
- Prefer compile-time checks (`static assert`) over runtime checks

### Naming
- Files/Directories: `snake_case` (e.g., `waku_lightpush`, `peer_manager`)
- Procedures: `camelCase` (e.g., `handleRequest`, `pushMessage`)
- Types: `PascalCase` (e.g., `WakuFilter`, `PubsubTopic`)
- Constants: `PascalCase` (e.g., `MaxContentTopicsPerRequest`)
- Constructors: `func init(T: type Xxx, params): T`
- For ref types: `func new(T: type Xxx, params): ref T`
- Exceptions: `XxxError` for CatchableError, `XxxDefect` for Defect
- ref object types: `XxxRef` suffix

### Calls and Member Access
- Prefer dot call syntax for predicates: `x.isNil()` instead of `isNil(x)`
- Use parentheses for "verbs" (operations/actions): `isSome()`, `handleRequest()`
- Omit parentheses for "nouns" (properties/values): `.len`, `.high`

### Imports Organization
Stdlib + external in one `import` block, internal modules in a separate block:
```nim
import
  std/[options, sequtils],      # stdlib
  results, chronicles, chronos,  # external
  libp2p/peerid
import
  ../node/peer_manager,          # internal (separate import block)
  ../waku_core,
  ./common
```

### Async Programming
Uses chronos, not stdlib `asyncdispatch`:
```nim
proc handleRequest(
    wl: WakuLightPush, peerId: PeerId
): Future[WakuLightPushResult] {.async.} =
  let res = await wl.pushHandler(peerId, pubsubTopic, message)
  return res
```

### Error Handling
The project uses both Result types and exceptions:

Result types from nim-results are used for protocol and API-level errors:
```nim
proc subscribe(
    wf: WakuFilter, peerId: PeerID
): Future[FilterSubscribeResult] {.async.} =
  if contentTopics.len > MaxContentTopicsPerRequest:
    return err(FilterSubscribeError.badRequest("exceeds maximum"))

  # Handle Result with isOkOr
  (await wf.subscriptions.addSubscription(peerId, criteria)).isOkOr:
    return err(FilterSubscribeError.serviceUnavailable(error))

  ok()
```

Exceptions still used for:
- chronos async failures (CancelledError, etc.)
- Database/system errors
- Library interop

Most files start with `{.push raises: [].}` to disable exception tracking, then use try/catch blocks where needed.

### Pragma Usage
```nim
{.push raises: [].}  # Disable default exception tracking (at file top)

proc myProc(): Result[T, E] {.async.} =  # Async proc
```

### Protocol Inheritance
Protocols inherit from libp2p's `LPProtocol`:
```nim
type WakuLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
```

### Type Visibility
- Public exports use `*` suffix: `type WakuFilter* = ...`
- Fields without `*` are module-private

## Style Guide Essentials

This section summarizes key Nim style guidelines relevant to this project. Full guide: https://status-im.github.io/nim-style-guide/

### Language Features

Import and Export
- Use explicit import paths with std/ prefix for stdlib
- Group imports: stdlib, external, internal (separate blocks)
- Export modules whose types appear in public API
- Avoid include

Macros and Templates
- Avoid macros and templates - prefer simple constructs
- Avoid generating public API with macros
- Put logic in templates, use macros only for glue code

Object Construction
- Prefer Type(field: value) syntax
- Use Type.init(params) convention for constructors
- Default zero-initialization should be valid state
- Avoid using result variable for construction

ref object Types
- Avoid ref object unless needed for:
  - Resource handles requiring reference semantics
  - Shared ownership
  - Reference-based data structures (trees, lists)
  - Stable pointer for FFI
- Use explicit ref MyType where possible
- Name ref object types with Ref suffix: XxxRef

Memory Management
- Prefer stack-based and statically sized types in core code
- Use heap allocation in glue layers
- Avoid alloca
- For FFI: use create/dealloc or createShared/deallocShared

Variable Usage
- Use most restrictive of const, let, var (prefer const over let over var)
- Prefer expressions for initialization over var then assignment
- Avoid result variable - use explicit return or expression-based returns

Functions
- Prefer func over proc
- Avoid public (*) symbols not part of intended API
- Prefer openArray over seq for function parameters

Methods (runtime polymorphism)
- Avoid method keyword for dynamic dispatch
- Prefer manual vtable with proc closures for polymorphism
- Methods lack support for generics

Miscellaneous
- Annotate callback proc types with {.raises: [], gcsafe.}
- Avoid explicit {.inline.} pragma
- Avoid converters
- Avoid finalizers

Type Guidelines

Binary Data
- Use byte for binary data
- Use seq[byte] for dynamic arrays
- Convert string to seq[byte] early if stdlib returns binary as string

Integers
- Prefer signed (int, int64) for counting, lengths, indexing
- Use unsigned with explicit size (uint8, uint64) for binary data, bit ops
- Avoid Natural
- Check ranges before converting to int
- Avoid casting pointers to int
- Avoid range types

Strings
- Use string for text
- Use seq[byte] for binary data instead of string

### Error Handling

Philosophy
- Prefer Result, Opt for explicit error handling
- Use Exceptions only for legacy code compatibility

Result Types
- Use Result[T, E] for operations that can fail
- Use cstring for simple error messages: Result[T, cstring]
- Use enum for errors needing differentiation: Result[T, SomeErrorEnum]
- Use Opt[T] for simple optional values
- Annotate all modules: {.push raises: [].} at top

Exceptions (when unavoidable)
- Inherit from CatchableError, name XxxError
- Use Defect for panics/logic errors, name XxxDefect
- Annotate functions explicitly: {.raises: [SpecificError].}
- Catch specific error types, avoid catching CatchableError
- Use expression-based try blocks
- Isolate legacy exception code with try/except, convert to Result

Common Defect Sources
- Overflow in signed arithmetic
- Array/seq indexing with []
- Implicit range type conversions

Status Codes
- Avoid status code pattern
- Use Result instead

### Library Usage

Standard Library
- Use judiciously, prefer focused packages
- Prefer these replacements:
  - async: chronos
  - bitops: stew/bitops2
  - endians: stew/endians2
  - exceptions: results
  - io: stew/io2

Results Library
- Use cstring errors for diagnostics without differentiation
- Use enum errors when caller needs to act on specific errors
- Use complex types when additional error context needed
- Use isOkOr pattern for chaining

Wrappers (C/FFI)
- Prefer native Nim when available
- For C libraries: use {.compile.} to build from source
- Create xxx_abi.nim for raw ABI wrapper
- Avoid C++ libraries

Miscellaneous
- Print hex output in lowercase, accept both cases

### Common Pitfalls

- Defects lack tracking by {.raises.}
- nil ref causes runtime crashes
- result variable disables branch checking
- Exception hierarchy unclear between Nim versions
- Range types have compiler bugs
- Finalizers infect all instances of type

## Common Workflows

### Adding a New Protocol
1. Create directory: `waku/waku_myprotocol/`
2. Define core files:
   - `rpc.nim` - Message types
   - `rpc_codec.nim` - Protobuf encoding
   - `protocol.nim` - Protocol handler
   - `client.nim` - Client API
   - `common.nim` - Shared types
3. Define protocol type in `protocol.nim`:
   ```nim
   type WakuMyProtocol* = ref object of LPProtocol
     peerManager: PeerManager
     # ... fields
   ```
4. Implement request handler
5. Mount in WakuNode (`waku/node/waku_node.nim`)
6. Add tests in `tests/waku_myprotocol/`
7. Export module via `waku/waku_myprotocol.nim`

### Adding a REST API Endpoint
1. Define handler in `waku/rest_api/endpoint/myprotocol/`
2. Implement endpoint following pattern:
   ```nim
   proc installMyProtocolApiHandlers*(
       router: var RestRouter, node: WakuNode
   ) =
     router.api(MethodGet, "/waku/v2/myprotocol/endpoint") do () -> RestApiResponse:
       # Implementation
       return RestApiResponse.jsonResponse(data, status = Http200)
   ```
3. Register in `waku/rest_api/handlers.nim`

### Adding Database Migration
For message_store (SQLite):
1. Create `migrations/message_store/NNNNN_description.up.sql`
2. Create corresponding `.down.sql` for rollback
3. Increment version number sequentially
4. Test migration locally before committing

For PostgreSQL: add in `migrations/message_store_postgres/`

### Running Single Test During Development
```bash
# Build test binary
make test tests/waku_filter_v2/test_waku_client.nim

# Binary location
./build/tests/waku_filter_v2/test_waku_client.nim.bin

# Or combine
make test tests/waku_filter_v2/test_waku_client.nim "specific test name"
```

### Debugging with Chronicles
Set log level and filter topics:
```bash
nim c -r \
  -d:chronicles_log_level=TRACE \
  -d:chronicles_disabled_topics="eth,dnsdisc" \
  tests/mytest.nim
```

## Key Constraints

### Vendor Directory
- Never edit files directly in vendor - it is auto-generated from git submodules
- Nimble dependencies are resolved from `nimble.lock` into `nimbledeps/`

### Chronicles Performance
- Log levels are configured at compile time for performance
- Runtime filtering is available but should be used sparingly: `-d:chronicles_runtime_filtering=on`
- Default sinks are optimized for production

### Memory Management
- Uses `refc` (reference counting with cycle collection)
- Automatically enforced by the build system (hardcoded in `waku.nimble`)
- Do not override unless absolutely necessary, as it breaks compatibility

### RLN Dependencies
- RLN code requires a Rust toolchain, which explains Rust imports in some modules
- `librln` is built from the vendored `zerokit` submodule via the `librln`/`rln-deps` Make targets

## Quick Reference

Language: Nim 2.x | License: MIT or Apache 2.0

### Important Files
- `Makefile` - Primary build interface
- `waku.nimble` - Package definition and build tasks (invoked by the Makefile via Nimble)
- `nimble.lock` - Pinned dependency versions resolved into `nimbledeps/`
- `waku/node/waku_node.nim` - Core node implementation
- `apps/wakunode2/wakunode2.nim` - Main CLI application
- `waku/factory/waku_conf.nim` - Configuration types
- `liblogosdelivery/liblogosdelivery.nim` - C bindings entry point

### Testing Entry Points
- `tests/all_tests_waku.nim` - All Waku protocol tests
- `tests/all_tests_wakunode2.nim` - Node application tests
- `tests/all_tests_common.nim` - Common utilities tests
#### in-flight testing
- any test can be run separately by issuing `make test tests/<relativepath>/<unit-test-source>.nim`
### Key Dependencies
- `chronos` - Async framework
- `nim-results` - Result type for error handling
- `chronicles` - Logging
- `libp2p` - P2P networking
- `confutils` - CLI argument parsing
- `presto` - REST server
- `nimcrypto` - Cryptographic primitives

Note: For specific version requirements, check `waku.nimble`.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **logos-delivery** (2076 symbols, 2564 relationships, 12 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/logos-delivery/context` | Codebase overview, check index freshness |
| `gitnexus://repo/logos-delivery/clusters` | All functional areas |
| `gitnexus://repo/logos-delivery/processes` | All execution flows |
| `gitnexus://repo/logos-delivery/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
