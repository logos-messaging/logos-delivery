# Waku v2 DNS-based Discovery Basic Tutorial

## Background

Waku v2 DNS discovery is a method by which a node may find other peers by retrieving an encoded node list via DNS.
To achieve this, Waku v2 uses a Nim implementation of [EIP-1459](https://eips.ethereum.org/EIPS/eip-1459).
According to EIP-1459, the peer list is encoded as a [Merkle tree](https://www.wikiwand.com/en/Merkle_tree) of TXT records.
Connectivity information for each peer, including [wire address](https://docs.libp2p.io/concepts/addressing/) and [peer ID](https://docs.libp2p.io/concepts/peer-id/), are encapsulated in signed [Ethereum Node Records (ENR)](https://eips.ethereum.org/EIPS/eip-778).

## Mapping ENR to `multiaddr`

EIP-1459 DNS discovery is a scheme for retrieving an ENR list via DNS.
Waku v2 addressing is based on [libp2p addressing](https://docs.libp2p.io/concepts/addressing/), which uses a `multiaddr` scheme.

The ENR is constructed according to [EIP-778](https://eips.ethereum.org/EIPS/eip-778).
It maps to the equivalent `libp2p` `multiaddr` for the Waku v2 node as follows:

| ENR Key     | ENR Value                                                              |
|-------------|------------------------------------------------------------------------|
| `id`        | name of identity scheme. For Waku v2 generally `v4`                    |
| `secp256k1` | the compressed `secp256k1` public key belong to the libp2p peer ID as per [specification](https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md#keys). This is used to construct the `/p2p/` portion of the node's `multiaddr` |
| ip          | IPv4 address. Corresponds to `/ip4/` portion of the node's `multiaddr` |
| tcp         | TCP port. Corresponds to `/tcp/` portion of the node's `multiaddr`     |

The `nim-waku` implementation with integrated DNS discovery already takes care of the ENR to `multiaddr` conversion.

## Usage

Ensure you have built [`logosdeliverynode`](https://github.com/status-im/nim-waku) or [`chat2`](./chat2.md) as per the linked instructions.

The following command line options are available for both `logosdeliverynode` or `chat2`.

```
--dns-discovery              Enable DNS Discovery
--dns-discovery-url          URL for DNS node list in format 'enrtree://<key>@<fqdn>'
```

- `--dns-discovery` is used to enable DNS discovery on the node. Waku DNS discovery is disabled by default.
- `--dns-discovery-url` is mandatory if DNS discovery is enabled. It contains the URL for the node list. The URL must be in the format `enrtree://<key>@<fqdn>` where `<fqdn>` is the fully qualified domain name and `<key>` is the base32 encoding of the compressed 32-byte public key that signed the list at that location. See [EIP-1459](https://eips.ethereum.org/EIPS/eip-1459#specification) or the example below to illustrate.

A node will attempt connection to all discovered nodes.

## Example for `waku.test` fleet

To illustrate the above and prove the concept,
a list of `waku.test` fleet nodes was encoded according to EIP-1459 and deployed to `test.waku.nodes.status.im`.
The list was signed by the public key `AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI`.
The complete URL for DNS discovery is therefore: `enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im`.

To run a `logosdeliverynode` with DNS-based discovery of `waku.test` nodes:

```
./build/logosdeliverynode --dns-discovery:true --dns-discovery-url:enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im
```

Similarly, for `chat2`:

```
./build/chat2 --dns-discovery:true --dns-discovery-url:enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im
```

The node will discover and attempt connection to all `waku.test` nodes during setup procedures.

To use specific DNS name servers, one or more `--dns-addrs-name-server` arguments can be added:

```
./build/logosdeliverynode --dns-discovery:true --dns-discovery-url:enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im --dns-addrs-name-server:8.8.8.8 --dns-addrs-name-server:8.8.4.4
```
