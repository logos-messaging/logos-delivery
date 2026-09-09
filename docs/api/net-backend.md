# Running the Edge protocols over another module's libp2p node

A node normally owns its libp2p stack. When another module in the same process
already runs a libp2p node, that module can register a *net backend* with
`liblogosdelivery`, and a node created with `"libp2pProvider": "<name>"` then
runs its Edge protocols over that node. The process then holds one identity and
one socket set.

```json
{
  "mode": "Edge",
  "preset": "logos.test",
  "kernelConf": { "nodekey": "<hex private key>" },
  "libp2pProvider": "libp2p_module"
}
```

Both sides must hold the same private key, or the two peer IDs diverge.

## C ABI

`library/liblogosdelivery.h` declares both symbols. The ABI version is 1.

```c
int logosdelivery_register_net_backend(const char *name,
                                       const LogosDeliveryNetBackendTable *table,
                                       void *userData);
int logosdelivery_net_backend_respond(uint64_t requestId, int ok,
                                      const char *data, size_t len);
```

Register the backend before you create the node. The library then calls
`table->submit(requestId, opJson, opLen, userData)` on its own thread with
`{"op": "<name>", "args": {...}}`. `submit` must return at once, and every
request must get exactly one `logosdelivery_net_backend_respond`, from any
thread: `ok != 0` carries the result JSON, `ok == 0` the error text. An op with
no answer within its timeout fails on the library side and its answer is then
dropped.

## Ops

| op | args | result |
| --- | --- | --- |
| `connectPeer` | `{peerId, multiaddrs, timeoutMs}` | `{}` |
| `dial` | `{peerId, proto}` | the stream id |
| `protocolRequest` | `{peerId, proto, multiaddrs, requestB64, timeoutMs, maxSize, expectResponse}` | `{responseB64}` |
| `mountProtocol` | `{proto}` | `{}` |
| `protocolAcceptStream` | `{proto, timeoutMs}` | `{streamId, proto, peerId}` |
| `streamReadLp` | `{streamId, maxSize, timeoutMs}` | `{dataB64}` |
| `streamWriteLp` | `{streamId, dataB64}` | `{}` |
| `streamClose` / `streamRelease` | `{streamId}` | `{}` |

A request/response exchange costs one `protocolRequest`. An inbound stream costs
one `protocolAcceptStream` plus one op per frame, so a long poll holds one worker
on the backend side for its whole timeout.

## Limits

- Edge protocols only. `createNode` rejects a config that enables relay, because
  gossipsub needs a real `PubSub` object mounted on a switch.
- discv5 stays off. It owns a UDP socket and signs with the node key, so
  `createNode` turns it off and says so in the log. Use entry nodes and peer
  exchange.
- The local switch is built but never started, and it serves the peer store
  alone. That store and the backend's own peer store drift apart: a bridged node
  answers `getPeersByProtocol` from peers it was told about, not from peers the
  backend knows. Give a service peer explicitly until the peer store ops exist.
- The node still advertises the addresses it was configured with, in its ENR and
  in peer exchange, and nothing listens on them. The backend's own addresses are
  the reachable ones.
- A backend restart invalidates every stream id. Create the node again.
- A bridged stream carries whole length-prefixed frames. A raw `write` or
  `readOnce` on it fails.
