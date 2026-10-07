# Run a Messaging API node

A node started with `--entry-layer=messaging` runs the Messaging API. With `--rest=true`, it serves the API at `/messaging/v1`. A client sends a message with `POST /messaging/v1/messages`. Then it reads the events of the send, such as `propagated`, `sent` and `error`, as JSON from `GET /messaging/v1/events/send/{requestId}`, about once per second. [REST API](../../api/rest-api.md#messaging-api) describes the API.

## Network

- Set a network preset (`--preset=twn`, `--preset=logos.dev`, `--preset=logos.test` or `--preset=status.prod`), or set `--cluster-id` and `--num-shards-in-network`.

## Messaging API flags

| Flag | What it sets | Default |
|---|---|---|
| `--reliability` | Confirm each send with a Store node | on, off for the `twn` and `status.prod` presets |
| `--anonymity-level` | Mix anonymity level: `None`, `Preferred` or `Required`. A level above `None` mounts mix. | `None` |

## Store nodes

The `sent` event of a send confirms that a Store node has the message. Run Store nodes with `--store=true`.

- A Store node does not confirm its own sends, so give each sender another Store node as a peer.
- Without a Store peer, each send gets an `error` event about a minute after it goes out.
- Without Store nodes, set `--reliability=false`.

## Readiness

Before the first send, wait until the `connectionStatus` field of `GET /health` is `Connected` or `PartiallyConnected`.

## Service limits

All Edge clients of a service node share its lightpush limit, `lightpush:5/1s` by default. For many Edge nodes, raise it with `--rate-limit`, for example `--rate-limit=lightpush:100/1s` (100 messages per second). `--rate-limit` entries are merged over the defaults (`filter:100/1s`, `lightpush:5/1s`, `px:5/1s`), so protocols you do not name keep their default.

## Received messages

- The REST API keeps the newest `--rest-messaging-cache-capacity` received messages until a client reads them with `GET /messaging/v1/events/received`. Set it to more than the number of messages that the node receives between two reads.
