# Waku

This folder contains code related to Waku, both as a node and as a protocol.

## Introduction

This is an implementation in Nim of the Waku suite of protocols.

See [specifications](https://rfc.vac.dev/waku/standards/core/10/waku2).

## How to Build & Run

### Prerequisites

* GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.

### Wakunode binary

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make wakunode2

# See available command line options
./build/wakunode2 --help

# Connect the client directly with the Status test fleet
# TODO NYI
#./build/wakunode2 --log-level:debug --discovery:off --fleet:test --log-metrics
```

Note: building `wakunode2` requires 2GB of RAM. The build will fail on systems not fulfilling this requirement.

Setting up a `wakunode2` on the smallest [digital ocean](https://docs.digitalocean.com/products/droplets/how-to/) droplet, you can either

* compile on a stronger droplet featuring the same CPU architecture and downgrade after compiling, or
* activate swap on the smallest droplet, or
* use Docker.


### Waku Protocol Test Suite

```bash
# Run all the Waku tests
make test
```

To run a specific test file or test case:
```bash
# Run all tests in a specific file
make test tests/waku_filter_v2/test_waku_filter.nim

# Run a specific test case within a file
make test tests/waku_filter_v2/test_waku_filter.nim "specific test name"
```

Alternatively, you can invoke the Nim compiler directly. For more on available flags, refer to the [compiler flags](https://nim-lang.org/docs/nimc.html#compiler-usage) and [chronicles documentation](https://github.com/status-im/nim-chronicles#compile-time-configuration).

```bash
nim c -r -d:chronicles_log_level=WARN --verbosity=0 --hints=off ./tests/waku_filter_v2/test_waku_filter.nim
```

You may also want to change the `outdir` to a folder ignored by git.
```bash
nim c -r -d:chronicles_log_level=WARN --verbosity=0 --hints=off --outdir=build ./tests/waku_filter_v2/test_waku_filter.nim
```

### Waku Protocol Example

There are basic examples of both publishing and subscribing,
more limited in features and configuration than the `wakunode2` binary,
located in `examples/`.

There is also a more full featured example in `apps/chat2/`.

## Using Metrics

Metrics are available for Waku nodes.

```bash
make wakunode2
./build/wakunode2 --metrics-server
```

Ensure your Prometheus config `prometheus.yml` contains the targets you care about, e.g.:

```
scrape_configs:
  - job_name: "waku"
    static_configs:
      - targets: ['localhost:8008', 'localhost:8009', 'localhost:8010']
```

For visualisation, similar steps can be used as is written down for Nimbus
[here](https://github.com/status-im/nimbus#metric-visualisation).

There is a similar example dashboard that includes visualisation of the
envelopes available at `metrics/waku-grafana-dashboard.json`.

## Spec support

All Waku RFCs reside at rfc.vac.dev.
Note that Waku specs are titled `WAKU2-XXX`
to differentiate them from a previous legacy version of Waku with RFC titles in the format `WAKU-XXX`.
The legacy Waku protocols are stable, but not under active development.

## Generating and configuring a private key

By default a node will generate a new, random key pair each time it boots,
resulting in a different public libp2p `multiaddrs` after each restart.

To maintain consistent addressing across restarts,
it is possible to configure the node with a previously generated private key using the `--nodekey` option.

```shell
wakunode2 --nodekey=<64_char_hex>
```

This option takes a [Secp256k1](https://en.bitcoin.it/wiki/Secp256k1) private key in 64 char hexstring format.

To generate such a key on Linux systems,
use the openssl `rand` command to generate a pseudo-random 32 byte hexstring.

```sh
openssl rand -hex 32
```

Example output:

```sh
$ openssl rand -hex 32
6a29e767c96a2a380bb66b9a6ffcd6eb54049e14d796a1d866307b8beb7aee58
```

where the key `6a29e767c96a2a380bb66b9a6ffcd6eb54049e14d796a1d866307b8beb7aee58` can be used as `nodekey`.

To create a reusable keyfile on Linux using `openssl`,
use the `ecparam` command coupled with some standard utilities
whenever you want to extract the 32 byte private key in hex format.

```sh
# Generate keyfile
openssl ecparam -genkey -name secp256k1 -out my_private_key.pem
# Extract 32 byte private key
openssl ec -in my_private_key.pem -outform DER | tail -c +8 | head -c 32| xxd -p -c 32
```

Example output:

```sh
read EC key
writing EC key
0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23
```

where the key `0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23` can be used as `nodekey`.

```sh
wakunode2 --nodekey=0c687bb8a7984c770b566eae08520c67f53d302f24b8d4e5e47cc479a1e1ce23
```

## Configuring a domain name

It is possible to configure an IPv4 DNS domain name that resolves to the node's public IPv4 address.

```shell
wakunode2 --dns4-domain-name=mynode.example.com
```

This allows for the node's publicly announced `multiaddrs` to use the `/dns4` scheme.
In addition, nodes with domain name and [secure websocket configured](#enabling-websocket),
will generate a discoverable ENR containing the `/wss` multiaddr with `/dns4` domain name.
This is necessary to verify domain certificates when connecting to this node over secure websocket.

## Using DNS discovery to connect to existing nodes

A node can discover other nodes to connect to using [DNS-based discovery](../docs/tutorial/dns-disc.md).
The following command line options are available:

```
--dns-discovery              Enable DNS Discovery
--dns-discovery-url          URL for DNS node list in format 'enrtree://<key>@<fqdn>'
--dns-addrs-name-server  DNS name server IPs to query. Argument may be repeated.
```

- `--dns-discovery` is used to enable DNS discovery on the node.
Waku DNS discovery is disabled by default.
- `--dns-discovery-url` is mandatory if DNS discovery is enabled.
It contains the URL for the node list.
The URL must be in the format `enrtree://<key>@<fqdn>` where `<fqdn>` is the fully qualified domain name and `<key>` is the base32 encoding of the compressed 32-byte public key that signed the list at that location.

A node will attempt connection to all discovered nodes.

This can be used, for example, to connect to one of the existing fleets.
Current URLs for the published fleet lists:
- production fleet: `enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im`
- test fleet: `enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im`

See the [separate tutorial](../docs/tutorial/dns-disc.md) for a complete guide to DNS discovery.

## Enabling Websocket

Websocket is currently the only Waku transport supported by browser nodes that uses [js-waku](https://github.com/status-im/js-waku).
Setting up websocket enables your node to directly serve browser peers.

A valid certificate is necessary to serve browser nodes,
you can use [`letsencrypt`](https://letsencrypt.org/):

```shell
sudo letsencrypt -d <your.domain.name>
```

You will need the `privkey.pem` and `fullchain.pem` files.

To enable secure websocket, pass the generated files to `wakunode2`:
Note, the default port for websocket is 8000.

```shell
wakunode2 --websocket-secure-support=true --websocket-secure-key-path="<letsencrypt cert dir>/privkey.pem" --websocket-secure-cert-path="<letsencrypt cert dir>/fullchain.pem"
```

### Self-signed certificates

Self-signed certificates are not recommended for production setups because:

- Browsers do not accept self-signed certificates
- Browsers do not display an error when rejecting a certificate for websocket.

However, they can be used for local testing purposes:

```shell
mkdir -p ./ssl_dir/
openssl req -x509 -newkey rsa:4096 -keyout ./ssl_dir/key.pem -out ./ssl_dir/cert.pem -sha256 -nodes
wakunode2 --websocket-secure-support=true --websocket-secure-key-path="./ssl_dir/key.pem" --websocket-secure-cert-path="./ssl_dir/cert.pem"
```