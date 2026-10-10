# Configure store protocol

> :information_source: This instructions apply to nwaku version v0.13.0+. For versions prior to v0.13.0, check [this page](./configure-store-v0.12.0.md).

The waku store protocol is disabled by default the nwaku node.
This is controlled by the `--store` option. To enable waku store protocol on startup, specify explicitly the `--store` option set to `true`:

```shell
logosdeliverynode --store=true
```

This option controls the mounting of the Waku Store protocol, meaning that your node will indicate to other peers that it supports the Waku store protocol.

## Configuring the node as a waku store client

Provide at least one store service node address with the `--storenode` option. This option is independent of the `--store` option i.e., one node can act as a waku store client without mounting the Waku Store protocol.

For example, to use the peer at `/dns4/node-01.ac-cn-hongkong-c.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp` as the waku store service node:

```shell
logosdeliverynode \
  --storenode=/dns4/node-01.ac-cn-hongkong-c.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp
```

Your node can now send queries to retrieve historical messages
from the configured store service node. One way to trigger such queries is asking your node for historical messages using the [Waku v2 JSON RPC API](https://rfc.vac.dev/spec/16/).

## Configuring the node as a store service node

If the waku store node is enabled (the `--store` option is set to `true`) the node will store historical messages and will be able to serve those messages to the waku store clients.

There is a set of configuration options to customize the waku store protocol's message store. These are the most relevant:

* `--store-message-retention-policy`: This option controls the retention policy i.e., how long certain messages will be persisted. Three different retention policies are supported:
  + The time retention policy,`time:<duration-in-seconds>` (e.g., `time:14400`)
  + The capacity retention policy,`capacity:<messages-count>` (e.g, `capacity:25000`)
  + The size retention policy,`size:<size-in-gb-mb>` (e.g, `size:25Gb`)
  + Several policies can be combined with `;` (e.g., `time:14400;size:25Gb`). Each one deletes messages on its own.
* `--store-message-db-url`: The message store database url option controls the message storage engine. This option follows the [_SQLAlchemy_ database URL format](https://docs.sqlalchemy.org/en/14/core/engines.html#database-urls).

  + SQLite engine: The only database engine supported by the nwaku node. The database URL has this shape: `sqlite://<database-file-path>`. If the `<database-file-path>` is not an absolute path (preceded by a `/` character), the file will be created in the current working directory. The SQLite engine also supports to select a non-persistent in-memory database by setting the `<database-file-path>` to `:memory:`.
  + In the case you don't want to use a persistent message store; set the `--store-message-db-url` to an empty string, `""`. This will instruct the node to use the fallback in-memory message store.

By default the node message store will be configured with a time retention policy set to `172800` seconds (2 days). Additionally, by default, the node message store will use the SQLite database engine to store historical messages in order to persist these between restarts.

> :warning: Note the 3 slashes, `///`,  after the SQLite database URL schema. The third slash indicates that it is an absolute path: `/mnt/nwaku/data/db1/store.sqlite3`

```shell
logosdeliverynode \
  --store=true \
  --store-message-db-url=sqlite:///mnt/nwaku/data/db1/store.sqlite3 \
  --store-message-retention-policy=capacity:150000
```

### Retention policy and store sync

With store sync enabled (`--store-sync=true`), the node reconciles the messages of the last `--store-sync-range` seconds (default `3600`), excluding the most recent `--store-sync-relay-jitter` seconds (default `20`). Peers push any message in that window that the node is missing. If the retention policy deletes messages that are still inside that window, the node downloads them again after a restart, and while running it advertises messages it can no longer serve.

* If the `time` retention is shorter than `--store-sync-range` plus `--store-sync-relay-jitter`, the node reduces the sync range to the retention minus the jitter and logs a warning with both values. To avoid the warning, set `--store-sync-range` to at most that value, or raise the time retention; e.g. `time:3620` keeps the default range of `3600`.
* A `capacity` retention is not adjusted: if more messages than the capacity arrive within the sync range, the oldest of them are deleted while still inside the sync window.
* A `size` retention deletes messages inside the sync range only when the size limit is reached.

### How much resources should I allocate?

Currently store service nodes use, by default, a message store backed by an in-disk SQLite database. Most Waku messages average a size of 1KB - 2KB, implying a minimum memory requirement of at least ~250MB
for a typical store capacity of 100k messages. Note, however, that the allowable maximum size for Waku messages is up to 1MB.
