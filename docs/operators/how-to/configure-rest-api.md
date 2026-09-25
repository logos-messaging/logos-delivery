# Configure a REST API node

A subset of the node configuration can be used to modify the behaviour of the HTTP REST API.

These are the relevant command line options:

| CLI option | Description | Default value |
|------------|-------------|---------------|
|`--rest` | Enable Waku REST HTTP server. | `false` |
|`--rest-address` | Listening address of the REST HTTP server. | `127.0.0.1` |
|`--rest-port` | Listening port of the REST HTTP server. | `8645` |
|`--rest-relay-cache-capacity` | Capacity of the Relay REST API message cache. | `50` |
|`--rest-messaging-cache-capacity` | Capacity of the messaging REST received cache (`GET /messaging/v1/events/received`). The cache keeps the newest messages until a poll, and one poll returns all of them. Minimum 1. Each record's `seq` and the `logos_delivery_rest_received_dropped_total` metric report evictions. Used only with `--entry-layer=messaging` or `--entry-layer=channels`. | `50` |
|`--rest-admin` | Enable access to REST HTTP Admin API. | `false` |
|`--rest-allow-origin` | Allow cross-origin requests from the given origin (`*` and `?` wildcards; may be repeated). | none |

Note that these command line options have their counterpart option in the node configuration file.

The node mounts the `/messaging/v1` routes only with `--entry-layer=messaging` or
`--entry-layer=channels`. The routes need autosharding: a network `--preset` or
`--num-shards-in-network`. See [REST API](../../api/rest-api.md#messaging-api).

Example:

```shell
logosdeliverynode --rest=true
```

The `page_size` flag in the Store API has a default value of 20 and a max value of 100.
