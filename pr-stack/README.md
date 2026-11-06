# PR stack for #4341 (pluggable nim-libp2p)

Cut on top of `origin/master` (7e8375a2c). Apply in order; each patch builds and
passes its tests on top of the previous ones. PR 1 targets `master`, every other
PR targets the one before it.

```bash
git apply pr-stack/01-host-foundation.patch   # then commit, and so on in order
```

| # | Patch | Adds / removes | What |
|---|---|---|---|
| 1 | 01-host-foundation | +379 / −69 | `IStream`/`IHost` concepts, `Libp2pHost`, `WakuNode.host`, rate-limiter generics, metadata protocol as the pilot, mock-stream test |
| 2 | 02-peer-manager-on-host | +277 / −280 | `PeerManager` on the host (`selfPeerId`, `peerStore`, connections, events), switch and dialer moved to `libp2p_backend/` |
| 3 | 03-store-filter-lightpush-streams | +369 / −385 | store, filter, lightpush ×2 stop inheriting `LPProtocol` (`handleStream`) |
| 4 | 04-peer-exchange-store-sync-setup | +274 / −201 | peer exchange and store sync likewise, `setupProtocols` split into helpers |
| 5 | 05-pubsub-interface | +228 / −0 | owned pubsub types, `IPubSub` concept, relay parameters (new files only) |
| 6 | 06-gossipsub-backend | +381 / −0 | `GossipSubBackend` implementing `IPubSub` (new file only) |
| 7 | 07-generic-relay | +559 / −607 | `WakuRelayOf[P: IPubSub]` and every relay consumer and test (atomic: the relay API changes) |
| 8 | 08-cleanup-and-import-boundary | +316 / −112 | peer-store wrapper removal, remaining accessor sites, import cleanups, `scripts/check_libp2p_imports.py`, CI job, docs |

Not included: the Logos-module backend (contract, transport, adapters, C ABI,
`libp2pImpl`), which is out of scope for now.
