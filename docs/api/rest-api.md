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
| `/messaging` | The Messaging API: subscribe and send by content topic, and poll the send and received events. See [Messaging API](#messaging-api). |


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

The `/messaging/v1` routes serve the Messaging API over REST. The node mounts them only with
`--entry-layer=messaging` or `--entry-layer=channels`. A kernel-only node answers `404` with
that hint. The routes need autosharding: set a network preset (`--preset=logos.test`, ...)
or `--cluster-id` with `--num-shards-in-network`.

```bash
# a service node: runs the Store service that confirms sends and serves backfill
logosdeliverynode --entry-layer=messaging --mode=core --preset=logos.test \
  --rest=true --rest-address=127.0.0.1 --rest-port=8645 --store=true
# a client node: uses this Store peer to confirm its sends (or finds one through discovery)
logosdeliverynode --entry-layer=messaging --mode=core --preset=logos.test \
  --rest=true --rest-address=127.0.0.1 --rest-port=8645 --storenode=<multiaddr>
```

| Method and route | Body | Response |
|---|---|---|
| `POST /messaging/v1/subscriptions` | `["/app/1/topic/proto", ...]` | `200 OK` |
| `DELETE /messaging/v1/subscriptions` | `["/app/1/topic/proto", ...]` | `200 OK` |
| `POST /messaging/v1/messages` | `{"payload":"<base64>","contentTopic":"/app/1/topic/proto","ephemeral":false,"meta":"<base64>"}` | `{"requestId":"..."}` |
| `GET /messaging/v1/events/send` | | every buffered send status, then cleared |
| `GET /messaging/v1/events/send/{requestId}` | | the send status of one request, then cleared; `404` while nothing is buffered for it |
| `GET /messaging/v1/events/received` | | the buffered received messages, oldest first, then cleared; each record has a `seq` |

A send is asynchronous. `200` means that the node accepted the message. The result arrives as
send events with the same `requestId`:

* `queued`: the send waits for rate-limit budget (only when rate limiting is on)
* `propagated`: the message reached at least one peer
* `sent`: a Store peer confirmed that it holds the message, or, for a send over mix, the mix
  exit replied
* `error`: the send failed (rejected message, no peer within the retry window, no Store
  confirmation within about 60 s of propagation, ...)

`sent` and `error` are final. `sent` needs store-based reliability, and never comes for an
ephemeral message. A send over the plain path also needs a Store peer for `sent`. A
`logosdeliverynode` started from the command line always has reliability on. For library and
JSON configs, the network preset sets it (on for `logos.dev` and `logos.test`, off for `twn` and
`status.prod`, on without a preset), and `reliability` overrides the preset. Without
reliability, and for an ephemeral message, `propagated` is the last event. Clients must ignore
kinds that they do not know. A `404` on `GET /events/send/{requestId}` means that nothing is
buffered for that id now: the id is unknown, already polled, or has no event yet. Keep polling
until the last event.

Each received record has the message hash, the full `WakuMessage` and a `source`: `live` for a
message that arrived when it was published, `history` for a message that a Store peer returned
at startup or after a connectivity gap. The node buffers only the content topics subscribed
through `/messaging/v1/subscriptions`. A relay subscription to the shard is not sufficient. A
send subscribes the node to its content topic, so the sender also receives its own messages.

A poll clears what it returns, for every client. The received buffer keeps the newest
`--rest-messaging-cache-capacity` messages (default 50) and drops the oldest when full. These
signals report evictions:

* each received record has a `seq`, from 1 without gaps
* the metric `logos_delivery_rest_received_dropped_total`

With one polling client, a gap in `seq` between two polls is the number of evicted records.
With more clients, a gap can also be records that another client polled. `seq` starts again at
1 when the node restarts.

An eviction is an observation loss of the client, not a network loss. To stop it, poll faster
or increase the capacity. The `Message received` log line and the
`logos_delivery_recv_messages_total{source=...}` metric count every delivery.

Malformed bodies and content topics answer `400`. A node without autosharding answers `503`.

### Node configuration
Find details [here](../operators/how-to/configure-rest-api.md)
