# Run a Messaging API node

A node started with `--entry-layer=messaging` runs the Messaging API. With `--rest=true`, it serves the API at `/messaging/v1`. A client sends a message with `POST /messaging/v1/messages`. Then it reads the events of the send, such as `propagated`, `sent` and `error`, as JSON from `GET /messaging/v1/events/send/{requestId}`, about once per second. [REST API](../../api/rest-api.md#messaging-api) describes the API.

## Network

- Set a network preset (`--preset=twn`, `--preset=logos.dev`, `--preset=logos.test` or `--preset=status.prod`), or set `--cluster-id` and `--num-shards-in-network`.

## Messaging API flags

| Flag | What it sets | Default |
|---|---|---|
| `--reliability` | Confirm each send with a Store node | on, off for the `twn` and `status.prod` presets |
| `--anonymity-level` | Anonymity level: `None`, `Preferred` or `Required`. A level above `None` mounts mix. | `None` |
| `--rate-limit-enabled` | Enforce the send rate limit | `false` |
| `--rate-limit-epoch-sec` | Epoch length, in seconds | `600` |
| `--rate-limit-messages-per-epoch` | Sends allowed per epoch | `1` |
| `--rate-limit-approached-threshold-percent` | Share of the epoch limit, in percent, at which the quota counts as approached | `80` |
| `--max-parked-age-sec` | Longest wait for rate-limit budget, in seconds | `1800` |
| `--send-queue-capacity` | Sends kept until their final event | `1000` |
| `--backfill-enabled` | Get missed messages from Store at startup | `true` |
| `--backfill-request-timeout-seconds` | Time limit of one Store query at startup, in seconds | `10` |

- With `--rate-limit-enabled=true`, set `--rate-limit-messages-per-epoch` and `--rate-limit-epoch-sec` to the rate that you need.
- `--rate-limit` is a different setting, for the services of the node (see [Service limits](#service-limits)).
- With large messages, raise `--backfill-request-timeout-seconds`.

## Store nodes

The `sent` event of a send confirms that a Store node has the message. Run Store nodes with `--store=true`.

- A Store node does not confirm its own sends, so give each sender another Store node as a peer.
- Without a Store peer, each send gets an `error` event about a minute after it goes out.
- Without Store nodes, set `--reliability=false`.

## Readiness

Before the first send, wait until the `connectionStatus` field of `GET /health` is `Connected` or `PartiallyConnected`.

## Service limits

All Edge clients of a service node share its lightpush limit, `lightpush:5/1s` by default. For many Edge nodes, raise it with `--rate-limit`, for example `--rate-limit=lightpush:100/1s` (100 messages per second).

## Received messages

- The REST API keeps the newest `--rest-messaging-cache-capacity` received messages until a client reads them with `GET /messaging/v1/events/received`. Set it to more than the number of messages that the node receives between two reads.
