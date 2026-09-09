# Configure store protocol (versions prior to v0.13.0)

> This page documents releases prior to v0.13.0, where the node binary was
> named `wakunode2`. The current binary is `logosdeliverynode`.

Store protocol is enabled by default on a nwaku node.
This is controlled by the `--store` CLI option.

```sh
# Disable store protocol on startup
./build/wakunode2 --store:false
```

Note that this only mounts the `store` protocol,
meaning your node will indicate to other peers that it supports `store`.
It does not yet allow your node to either retrieve historical messages as a client
or store and serve historical messages itself.

## Configuring a store client

Ensure that `store` is enabled (this is `true` by default) and provide at least one store service node address with the `--storenode` CLI option.

See the following example, using the peer at `/dns4/node-01.ac-cn-hongkong-c.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp` as store service node.

```sh
./build/wakunode2 \
  --store:true \
  --storenode:/dns4/node-01.ac-cn-hongkong-c.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp
```

Your node can now send queries to retrieve historical messages
from the configured store service node.
One way to trigger such queries is asking your node for historical messages using the [Waku v2 JSON RPC API](https://rfc.vac.dev/spec/16/).

## Configuring a store service node

To store historical messages on your node which can be served to store clients the `--persist-messages` CLI option must be enabled.
By default a node would store up to the latest `50 000` messages.
This is configurable using the `--store-capacity` option.
A node that has a `--db-path` set will backup historical messages to a local database at the DB path
and persist these messages even after a restart.

```sh
./build/wakunode2 \
  --store:true \
  --persist-messages:true \
  --db-path:/mnt/nwaku/data/db1/ \
  --store-capacity:150000
```

### How much resources should I allocate?

Currently store service nodes use an in-memory key-value store as primary storage with the disk-based database only used for backups.
Most Waku messages average a size of 1KB - 2KB,
implying a minimum memory requirement of at least ~250MB
for a medium capacity store of 100k messages.
Note, however, that the allowable maximum size for Waku messages is up to 1MB.
We are working on a disk-only and hybrid store to lower the memory requirement.
It will soon also be possible to configure store capacity on maximum store size or number of days' history to keep.
