# Run a Messaging API node

A node started with `--entry-layer=messaging` runs the Messaging API. With `--rest=true`, it serves the API at `/messaging/v1`. A client sends a message with `POST /messaging/v1/messages`. Then it reads the events of the send, such as `propagated`, `sent` and `error`, as JSON from `GET /messaging/v1/events/send/{requestId}`. [REST API](../../api/rest-api.md#messaging-api) describes the API.

## Network

- Set a network preset (`--preset=logos.test`, ...), or set `--cluster-id` and `--num-shards-in-network`.

## Store nodes

The `sent` event of a send confirms that a Store node has the message. Run Store nodes with `--store=true`.

- A Store node does not confirm its own sends, so give each sender another Store node as a peer.
- Without a Store peer, each send gets an `error` event about a minute after it goes out.

## Readiness

Before the first send, wait until the `connectionStatus` field of `GET /health` is `Connected` or `PartiallyConnected`.

## Service limits

All Edge clients of a service node share its lightpush limit, `lightpush:5/1s` by default. For many Edge nodes, raise it with `--rate-limit`, for example `--rate-limit=lightpush:100/1s`.

## Received messages

- The REST API keeps the newest `--rest-messaging-cache-capacity` received messages until a poll. Set it to more than the number of messages that the node receives between two polls.
