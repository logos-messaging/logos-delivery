# Running nwaku

Nwaku binaries can be [built](./build.md) and run on Linux and macOS.
Windows support is experimental.

```sh
# Run with default configuration
./build/wakunode2

# See available command line options
./build/wakunode2 --help
```

## Default configuration

By default a nwaku node will:
- generate a new private key and libp2p identities after every restart.
See [this tutorial](./configure-key.md) if you want to generate and configure a persistent private key.
- listen for incoming libp2p connections on the default TCP port (`60000`)
- enable `relay` protocol
- subscribe to the default clusterId (0) and shard (0)
- enable `store` protocol, but only as a client.
This implies that the nwaku node will not persist any historical messages itself,
but can query `store` service peers who do so.
To configure `store` as a service node,
see [this tutorial](./configure-store.md).

> **Note:** The `filter` and `lightpush` protocols are _not_ enabled by default.
Consult the [configuration guide](./configure.md) on how to configure your nwaku node to run these protocols.

Some typical non-default configurations are explained below.
For more advanced configuration, see the [configuration guide](./configure.md).
Different ways to connect to other nodes are expanded upon in our [connection guide](./connect.md).

## Finding your listening address(es)

Find the log entry beginning with `Listening on`.
It should be printed at INFO level when you start your node
and contains a list of all publicly announced listening addresses for the nwaku node.

For example

```
INF 2022-05-11 16:42:30.591+02:00 Listening on                               topics="wakunode" tid=6661 file=wakunode2.nim:941 full=[/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H][/ip4/0.0.0.0/tcp/8000/ws/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H]
```

indicates that your node is listening on the TCP transport address

```
/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H
```

and websocket address

```
/ip4/0.0.0.0/tcp/8000/ws/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H
```

If your node is running with QUIC enabled, the log also includes a QUIC address

```
/ip4/0.0.0.0/udp/60000/quic-v1/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H
```

You can also query a running node for its listening addresses
using the REST API.

```bash
curl http://localhost:8645/debug/v1/info -s | jq
```

## Finding your discoverable ENR address(es)

A nwaku node can encode its addressing information in an [Ethereum Node Record (ENR)](https://eips.ethereum.org/EIPS/eip-778) according to [`31/WAKU2-ENR`](https://rfc.vac.dev/spec/31/).
These ENR are most often used for discovery purposes.

### ENR for DNS discovery

Find the log entry beginning with `DNS: discoverable ENR`.
It should be printed at INFO level when you start your node with [DNS discovery enabled](./configure-dns-disc.md)
and contains an ENR that can be added to node lists discoverable via DNS.

For example

```
INF 2022-05-20 11:52:48.772+02:00 DNS: discoverable ENR                      topics="wakunode" tid=5182 file=wakunode2.nim:941 enr=enr:-Iu4QBZs5huNuEAjI9WA0HOAjzpmp39vKJAtYRG3HXH86-i3HGcxMgupIkyDBmBq9qJ2wFfgMiW8AUzUxTFMAzfJM5MBgmlkgnY0gmlwhAAAAACJc2VjcDI1NmsxoQN0EcrUbHrL_O_kNXDlBvcO1I4yZUdNk7VZI5GsXaWgvYN0Y3CC6mCFd2FrdTID
```

indicates that your node addresses are encoded in the ENR

```
enr=enr:-Iu4QBZs5huNuEAjI9WA0HOAjzpmp39vKJAtYRG3HXH86-i3HGcxMgupIkyDBmBq9qJ2wFfgMiW8AUzUxTFMAzfJM5MBgmlkgnY0gmlwhAAAAACJc2VjcDI1NmsxoQN0EcrUbHrL_O_kNXDlBvcO1I4yZUdNk7VZI5GsXaWgvYN0Y3CC6mCFd2FrdTID
```

### ENR for Discovery v5

Find the log entry beginning with `Discv5: discoverable ENR`.
It should be printed at INFO level when you start your node with [Waku Discovery v5 enabled](https://rfc.vac.dev/spec/33/)
and contains the ENR that will be discoverable by other peers.

For example

```
INF 2022-05-20 11:52:48.775+02:00 Discv5: discoverable ENR                   topics="wakunode" tid=5182 file=wakunode2.nim:905 enr=enr:-IO4QDxToTg86pPCK2KvMeVCXC2ADVZWrxXSvNZeaoa0JhShbM5qed69RQz1s1mWEEqJ3aoklo_7EU9iIBcPMVeKlCQBgmlkgnY0iXNlY3AyNTZrMaEDdBHK1Gx6y_zv5DVw5Qb3DtSOMmVHTZO1WSORrF2loL2DdWRwgiMohXdha3UyAw
```

indicates that your node addresses are encoded in the ENR

```
enr=enr:-IO4QDxToTg86pPCK2KvMeVCXC2ADVZWrxXSvNZeaoa0JhShbM5qed69RQz1s1mWEEqJ3aoklo_7EU9iIBcPMVeKlCQBgmlkgnY0iXNlY3AyNTZrMaEDdBHK1Gx6y_zv5DVw5Qb3DtSOMmVHTZO1WSORrF2loL2DdWRwgiMohXdha3UyAw
```

## Typical configuration (relay node)

The typical configuration for a nwaku node is to run the `relay` protocol,
subscribed to the default pubsub topic `/waku/2/rs/0/0`,
and connecting to one or more existing peers.
We assume below that running nodes also participate in Discovery v5
to continually discover and connect to random peers for a more robust mesh.

### Connecting to known peer(s)

A typical run configuration for a nwaku node is to connect to existing peers with known listening addresses using the `--staticnode` option.
The `--staticnode` option can be repeated for each peer you want to connect to on startup.
This is also useful if you want to run several nwaku instances locally
and therefore know the listening addresses of all peers.

As an example, consider a nwaku node that connects to two known peers
on the same local host (with IP `0.0.0.0`)
with TCP ports `60002` and `60003`,
and peer IDs `16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H` and `16Uiu2HAmFBA7LGtwY5WVVikdmXVo3cKLqkmvVtuDu63fe8safeQJ` respectively.
The Discovery v5 routing table can similarly be bootstrapped using a static ENR.
We include an example below.

```sh
./build/wakunode2 \
  --ports-shift:1 \
  --staticnode:/ip4/0.0.0.0/tcp/60002/p2p/16Uiu2HAkzjwwgEAXfeGNMKFPSpc6vGBRqCdTLG5q3Gmk2v4pQw7H \
  --staticnode:/ip4/0.0.0.0/tcp/60003/p2p/16Uiu2HAmFBA7LGtwY5WVVikdmXVo3cKLqkmvVtuDu63fe8safeQJ \
  --discv5-discovery:true \
  --discv5-bootstrap-node:enr:-JK4QM2ylZVUhVPqXrqhWWi38V46bF2XZXPSHh_D7f2PmUHbIw-4DidCBnBnm-IbxtjXOFbdMMgpHUv4dYVH6TgnkucBgmlkgnY0gmowhCJ6_HaJc2VjcDI1NmsxoQM06FsT6EJ57mzR_wiLu2Bz1dER2nUFSCpaFzCccQtnhYN0Y3CCdl-DdWRwgiMohXdha3UyDw
```

> **Tip:** `--ports-shift` shifts all configured ports forward by the configured amount.
This is another useful option when running several nwaku instances on a single machine
and would like to avoid port clashes without manually configuring each port.

### Connecting to the `waku.sandbox` network

*See [this explainer](https://github.com/status-im/nwaku/blob/6ebe26ad0587d56a87a879d89b7328f67f048911/docs/contributors/waku-fleets.md) on the different networks and Waku v2 fleets.*

You can use DNS discovery to bootstrap connection to the existing production network.
Discovery v5 will attempt to extract the ENRs of the discovered nodes as bootstrap entries to the routing table.

```sh
./build/wakunode2 \
  --ports-shift:1 \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im \
  --discv5-discovery:true
```

### Connecting to the `waku.test` network

*See [this explainer](https://github.com/status-im/nwaku/blob/6ebe26ad0587d56a87a879d89b7328f67f048911/docs/contributors/waku-fleets.md) on the different networks and Waku v2 fleets.*

You can use DNS discovery to bootstrap connection to the existing test network.
Discovery v5 will attempt to extract the ENRs of the discovered nodes as bootstrap entries to the routing table.

```sh
./build/wakunode2 \
  --ports-shift:1 \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im \
  --discv5-discovery:true
```

## Typical configuration (relay and store service node)

Often nwaku nodes choose to also store historical messages
from where it can be queried by other peers who may have been temporarily offline.
For example, a typical configuration for such a store service node,
[connecting to the `waku.test`](#connecting-to-the-wakutest-network) fleet on startup,
appears below.

```sh
./build/wakunode2 \
  --ports-shift:1 \
  --store:true \
  --persist-messages:true \
  --db-path:/mnt/nwaku/data/db1/ \
  --store-capacity:150000 \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im \
  --discv5-discovery:true
```

See our [store configuration tutorial](./configure-store.md) for more.

## Interact with a running nwaku node

A running nwaku node can be interacted with using the [REST API](https://github.com/waku-org/nwaku/blob/master/docs/api/rest-api.md).
