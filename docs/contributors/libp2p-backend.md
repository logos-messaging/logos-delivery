# The libp2p backend boundary

logos-delivery is built against interfaces for what it needs from a libp2p
stack, not against nim-libp2p. The nim-libp2p implementation is one backend
behind them, so another implementation (a Logos module) can be plugged in
without touching protocol or API code.

## Layout

| Directory | Role |
|---|---|
| `logos_delivery/waku/libp2p_iface/` | The interfaces: Nim `concept`s and the plain value types they use |
| `logos_delivery/waku/libp2p_backend/` | Implementations. The only place that may import the behavioural nim-libp2p modules |
| `logos_delivery/waku/waku_relay/` | Relay logic (Waku validation, topic health, metrics), generic over `IPubSub` |

## The interfaces

- **`IPubSub`** (`libp2p_iface/pubsub.nim`): subscribe, publish, validators,
  mesh/connected peers, events, parameters. Types are owned: `ValidationResult`,
  `PubSubParams`, `PubSubEvent`, peer ids as strings. `WakuRelayOf[P: IPubSub]`
  holds a `P`; `WakuRelay` is `WakuRelayOf[GossipSubBackend]`.
- **`IHost`** (`libp2p_iface/host.nim`): identity, addresses, start/stop,
  disconnect, connections, peer events. Streams and mounting are per backend,
  because they depend on the backend's stream type.
- **`IStream`** (`libp2p_iface/stream.nim`): `peerId`, `writeLP`, `readLp`,
  `close`, `closeWithEof`, `atEof`. Every request/response protocol
  (`metadata`, `store`, `filter`, `lightpush`, `peer exchange`, `store sync`)
  exposes `handleStream[S: IStream]` and is mounted with
  `host.mountHandler(codec, protocol)`; none inherits `LPProtocol`.

A backend is any type for which the calls compile, with no base class or
`method`. Each backend ends with a `static: doAssert Backend is IHost` so a
contract break fails its own build.

## Backends

- **Built-in** (`gossipsub.nim`, `host.nim`, `relay.nim`): nim-libp2p `GossipSub`
  and `Switch`, behaviour-identical to before. Used by `logosdeliverynode` and
  whenever no module is installed.
- **Module** (`module_pubsub.nim`, `module_host.nim`, `module_transport.nim`):
  adapters over an external libp2p Logos module. The contract is
  `libp2p_iface/module_contract.nim`: CBOR requests and events over plain
  values, with peer ids and multiaddresses as strings and streams as `uint64`
  handles, so each one maps onto a nim-ffi `{.ffi.}` request or `{.ffiEvent.}`.
  The C ABI is `library/liblogosdelivery_libp2p.h`
  (`logosdelivery_libp2p_set_module`, `_response`, `_event`).

Peer queries and connection lists are synchronous in the interfaces, so the
module adapters answer them from a snapshot that is refreshed on topology/peer
events and once a second.

## Selecting the implementation

The `libp2pImpl` parameter (`libp2p-impl`; `builtin` by default, or a module
name) is part of the node configuration. `logosdelivery_libp2p_set_module`
installs the module before node creation; installing a module while
`libp2pImpl` is `builtin`, or the reverse, is a startup error
(`checkLibp2pImpl` in `node_factory.nim`).

**Limitation:** a node still runs on a nim-libp2p `Switch` for its peer book
(`waku_peer_store.nim` extends libp2p's `PeerStore`), address management and the
libp2p-native protocols (ping, mix, kademlia, rendezvous, autonat). Naming a
module therefore fails at startup with "not supported by the node yet". The
adapters are complete and tested against a reference module
(`tests/libp2p_module/`); wiring a switch-less node needs the peer book behind
an interface first.

## Boundary check

`scripts/check_libp2p_imports.py` (CI job `libp2p-boundary`) fails when a file
outside the backend imports a behavioural nim-libp2p module (`switch`,
`protocols/*`, `stream/*`, `builders`, transports, ...). Modules that only
define plain value types shared by the whole code base (`peerid`,
`multiaddress`, `crypto/*`, ...) are exempt. Files that still import behaviour
are listed in `scripts/libp2p_imports_allowlist.txt`; the list only shrinks.
Run `scripts/check_libp2p_imports.py --update` after removing an import.

## Testing without nim-libp2p

Any type satisfying the concepts can back a protocol:
`tests/waku_metadata/test_mock_stream.nim` runs the metadata protocol over an
in-memory stream.
