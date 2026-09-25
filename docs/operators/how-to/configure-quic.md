# Configure QUIC transport

QUIC is a UDP-based transport. It is enabled by default and allows peers to connect to your node over QUIC, in addition to the TCP transport.
By default, QUIC listens on the same port number as TCP, over UDP: `--listen-port` sets both (60000 unless set). `--tcp-port` still works and QUIC follows it too.

When upgrading a node that ran without QUIC, open that UDP port in your firewall or port mappings, or run with `--quic-support=false`. Otherwise the node announces a QUIC address nobody can reach, and every peer dialing it waits a few seconds before falling back to TCP.

To listen on a different UDP port, use `--quic-port`:

```shell
logosdeliverynode --quic-port=<port>
```

To disable QUIC, use the `--quic-support` option:

```shell
logosdeliverynode --quic-support=false
```

QUIC runs alongside the existing TCP transport. The node keeps listening on TCP and announces a `/udp/<port>/quic-v1` address, so peers that support QUIC can connect over it while others continue to use TCP. The ENR carries that address once the node knows a host a peer can reach it on: an `--ext-ip`, a `--dns4-domain-name`, an `--ext-multiaddr`, a NAT mapping, or the host discv5 learns from its peers. Behind a NAT without a mapping, the ENR advertises the bound ports and no host.

If you restrict the node's announced addresses with `--ext-multiaddr-only`, the QUIC address is no longer announced automatically. In that case, include the QUIC multiaddr in `--ext-multiaddr` yourself, for example `/ip4/<ip>/udp/<port>/quic-v1`.
