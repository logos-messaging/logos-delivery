# logosdeliverynode docker compose stack

A `docker compose` project that runs a **logosdeliverynode** as a full service
node on the **Logos Dev** network (`--preset=logos.dev`), backed by Postgres
store and a Prometheus + Grafana monitoring stack.

It mirrors the [logos-delivery-compose](https://github.com/logos-messaging/logos-delivery-compose)
approach, adapted for the `logosdeliverynode` binary. RLN, the setup wizard and
RLN keystore tooling are intentionally omitted for now.

## Services

| Service                | Purpose                                                        |
| ---------------------- | ------------------------------------------------------------- |
| `logos-messaging-node` | The logosdeliverynode itself (relay + store + filter/lightpush) |
| `postgres`             | Persistent message store (`--store-message-db-url`)           |
| `postgres-exporter`    | Exposes Postgres metrics to Prometheus                        |
| `prometheus`           | Scrapes node (`:8003`) and postgres-exporter                  |
| `grafana`              | Dashboards (`http://localhost:3000`, anonymous admin)         |
| `certbot`              | Let's Encrypt certs for WebSocket-Secure; only with the `wss` profile |

## Quick start

```bash
cd apps/logos_delivery_node/docker
cp .env.example .env          # edit POSTGRES_PASSWORD etc.

# Build the logosdeliverynode image from the repo Dockerfile
# (or set LOGOS_IMAGE in .env to a prebuilt image and skip this)
docker compose build

docker compose up -d
docker compose logs -f logos-messaging-node
```

Check node health:

```bash
./chkhealth.sh                # queries http://localhost:8645/health
```

## Configuration

The node command lives in [`run_node.sh`](./run_node.sh). Network parameters
(cluster id, sharding, bootstrap nodes, RLN off) come from the network preset,
`logos.dev` by default. The top API layer defaults to `kernel` (transport only;
the messaging / reliable-channel REST layers are not mounted). Both are
configurable via `.env` — see `PRESET` / `ENTRY_LAYER` below.

Key `.env` values:

| Variable                    | Default   | Meaning                                             |
| --------------------------- | --------- | --------------------------------------------------- |
| `PRESET`                    | `logos.dev` | Network preset: `logos.dev`, `logos.test`, `twn`, `status.prod`. Empty = no preset (set cluster/shards via `EXTRA_ARGS`) |
| `ENTRY_LAYER`               | `kernel`  | Top API layer: `kernel` (transport only), `messaging`, or `channels` |
| `LOGOS_IMAGE`               | *(build)* | Prebuilt image; empty builds locally               |
| `POSTGRES_USER` / `_PASSWORD` | postgres / test123 | Store DB credentials                     |
| `NODEKEY`                   | *(random)* | Stable P2P identity (64 char hex)                  |
| `DOMAIN`                    | *(empty)* | Public domain for WebSocket-Secure; empty disables WSS |
| `COMPOSE_PROFILES`          | *(empty)* | Set to `wss` together with `DOMAIN` to run `certbot`   |
| `EMAIL`                     | `admin@$DOMAIN` | Let's Encrypt registration address            |
| `STORAGE_SIZE`              | `1GB`     | Store retention size                               |
| `EXTRA_ARGS`                | *(empty)* | Extra CLI flags appended to the node               |

Helper scripts `set_postgres_shm.sh` and `set_storage_retention.sh` can append
tuned `POSTGRES_SHM` / `STORAGE_SIZE` values to `.env` based on the host.

## Ports

| Port         | Service    | Notes                          |
| ------------ | ---------- | ------------------------------ |
| 30304 tcp/udp | node      | libp2p                         |
| 9005 udp     | node       | discv5                         |
| 8000 tcp     | node       | WebSocket-Secure               |
| 8645         | node REST  | bound to 127.0.0.1             |
| 8003         | node metrics | bound to 127.0.0.1           |
| 3000         | grafana    |                                |
| 80           | certbot    | ACME HTTP-01, only with the `wss` profile |

## WebSocket-Secure

WSS is off by default. To enable it, set both values in `.env` and bring the
stack back up:

```bash
DOMAIN=node.example.com
COMPOSE_PROFILES=wss
```

`certbot` publishes host port 80 for the ACME HTTP-01 challenge, which is why
it is kept behind a profile rather than started unconditionally. With `DOMAIN`
set but the profile off, no certificate is ever issued and the node stays in
its certificate-wait loop.
