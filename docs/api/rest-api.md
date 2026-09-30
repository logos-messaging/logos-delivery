## HTTP REST API

The HTTP REST API consists of a set of methods operating on the Waku Node remotely over HTTP.

This API is divided in different _namespaces_ which group a set of resources:

| Namespace | Description |
------------|--------------
| `/debug` | Information about a Waku v2 node. |
| `/relay` | Control of the relaying of messages. See [11/WAKU2-RELAY](https://rfc.vac.dev/spec/11/) RFC |
| `/store` | Retrieve the message history. See [13/WAKU2-STORE](https://rfc.vac.dev/spec/13/) RFC |
| `/filter` | Control of the content filtering. See [12/WAKU2-FILTER](https://rfc.vac.dev/spec/12/) RFC |
| `/admin` | Privileged access to the internal operations of the node. |
| `/messaging` | The Messaging API: subscribe and send by content topic, and read the send and received events. See [Messaging API](#messaging-api). |


### API Specification

The HTTP REST API has been designed following the OpenAPI 3.0.3 standard specification format.
The OpenAPI specification files can be found in the [Logos Delivery REST API Reference](https://github.com/logos-messaging/logos-delivery-rest-api) repository.

You can also use the [hosted OpenAPI UI](https://logos-messaging.github.io/logos-delivery-rest-api/) to explore and execute the calls locally.

Check the [OpenAPI Tools](https://openapi.tools/) site for the right tool for you (e.g. REST API client generator)

A particular OpenAPI spec can be easily imported into [Postman](https://www.postman.com/downloads/)
  1. Open Postman.
  2. Click on File -> Import...
  2. Load the openapi.yaml of interest, stored in your computer.
  3. Then, requests can be made from within the 'Collections' section.


### Usage example

#### [`get_waku_v2_debug_v1_info`](https://rfc.vac.dev/spec/16/#get_waku_v2_debug_v1_info)

```bash
curl http://localhost:8645/debug/v1/info -s | jq
```

### Store API

The `page_size` flag in the Store API has a default value of 20 and a max value of 100.

### Messaging API

The `/messaging/v1` routes serve the Messaging API over REST. The node mounts them only with `--entry-layer=messaging` or `--entry-layer=channels`. A node with `--entry-layer=kernel` answers HTTP `404`, with a hint to set one of these entry layers. The routes need autosharding: set a network preset (`--preset=twn`, `--preset=logos.dev`, `--preset=logos.test` or `--preset=status.prod`) or `--cluster-id` with `--num-shards-in-network`.

```bash
# a service node: runs the Store service that confirms sends and serves backfill
logosdeliverynode --entry-layer=messaging --mode=core --preset=logos.test \
  --rest=true --rest-address=127.0.0.1 --rest-port=8645 --store=true
# a client node: uses this Store peer to confirm its sends (or finds one through discovery)
logosdeliverynode --entry-layer=messaging --mode=core --preset=logos.test \
  --rest=true --rest-address=127.0.0.1 --rest-port=8645 --storenode=<multiaddr>
```

[Run a Messaging API node](../operators/how-to/run-messaging.md#messaging-api-flags) lists the Messaging API flags.

| Method and route | Body | Response |
|---|---|---|
| `GET /messaging/v1/subscriptions` | | `["/app/1/topic/proto", ...]`, sorted |
| `POST /messaging/v1/subscriptions` | `["/app/1/topic/proto", ...]` | `200 OK` |
| `DELETE /messaging/v1/subscriptions` | `["/app/1/topic/proto", ...]` | `200 OK` |
| `POST /messaging/v1/messages` | `{"payload":"<base64>","contentTopic":"/app/1/topic/proto","ephemeral":false,"meta":"<base64>"}` | `{"requestId":"..."}` |
| `GET /messaging/v1/events/send` | | every buffered send status, then cleared |
| `GET /messaging/v1/events/send/{requestId}` | | the send status of one request, then cleared; `404` while nothing is buffered for it |
| `GET /messaging/v1/events/received` | | the buffered received messages, oldest first, then cleared; each record has a `seq` |

A send is asynchronous. `200` means that the node accepted the message. The result arrives as send events with the same `requestId`:

* `queued`: the send waits for rate-limit budget (only when rate limiting is on)
* `propagated`: the message reached at least one peer
* `sent`: a Store peer confirmed that it holds the message, or, for a send over mix, the mix exit replied
* `error`: the send failed (rejected message, no peer within the retry window, no Store confirmation within about 60 s of propagation, ...)

After a `sent` or `error` event, no more events come for that message.

* The `sent` event needs reliability. A send without mix also needs a Store peer.
* A message sent with `"ephemeral": true` gets no `sent` event, because Store nodes do not keep ephemeral messages.
* Reliability is on by default, and off for the `twn` and `status.prod` presets. `--reliability` overrides that.
* Without reliability, or for an ephemeral message, `propagated` is the last event.
* Later versions can add new event types. A client must skip an event type that it does not know.
* `GET /messaging/v1/events/send/{requestId}` answers `404` while the node has no event for that request: the request id is unknown, a client already read its events, or no event came yet. Call it again until the last event comes.

The receivers can have the message after an `error` event. The node does not resend a message after its `propagated` event.

* Each received message comes as a JSON object with:
  * the message hash
  * the full `WakuMessage`
  * a `source`: `live` for a message that arrived when it was published, or `history` for a message that a Store peer returned at startup or after the node came back online
* The node keeps messages only for the content topics subscribed through `/messaging/v1/subscriptions`. A relay subscription to the shard is not enough.
* A send subscribes the node to its content topic, so the sender also receives its own messages.

At startup, the node gets from Store the messages that it missed while it was down. On its first start, it gets the last 24 h.

`GET /messaging/v1/events/received` returns the messages that arrived since the last call, and the node then removes them. With more than one client, each message goes to one client only. Between two calls, the node holds at most `--rest-messaging-cache-capacity` messages (default 50), and drops the oldest ones when more arrive. Two signals show dropped messages:

* Each message has a `seq` number that goes up by 1 for each message. A jump in `seq` between two calls is the number of dropped messages, or of messages that another client got. `seq` starts again at 1 when the node restarts.
* The metric `logos_delivery_rest_received_dropped_total` counts the dropped messages.

The send buffer keeps the statuses of the newest requests and drops the oldest when full. The metric `logos_delivery_rest_send_dropped_total` counts the dropped ones.

Malformed bodies and content topics get HTTP `400`. A node without autosharding answers HTTP `503`. A send to a full send queue gets HTTP `429` with a `Retry-After` header.

### Node configuration
To set up a network of Messaging API nodes, see [Run a Messaging API node](../operators/how-to/run-messaging.md).
