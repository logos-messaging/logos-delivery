# Configure QUIC transport

QUIC is a UDP-based transport. Enabling it allows peers to connect to your node over QUIC, in addition to the default TCP transport.

To enable QUIC, use the `--quic-support` option.
Note, the default port for QUIC is 60000.

```shell
wakunode2 --quic-support=true
```

To listen on a different UDP port, use `--quic-port`:

```shell
wakunode2 --quic-support=true --quic-port=<port>
```

QUIC runs alongside the existing TCP transport. The node keeps listening on TCP and announces a `/udp/<port>/quic-v1` address in its ENR, so peers that support QUIC can connect over it while others continue to use TCP.

If you restrict the node's announced addresses with `--ext-multiaddr-only`, the QUIC address is no longer announced automatically. In that case, include the QUIC multiaddr in `--ext-multiaddr` yourself, for example `/ip4/<ip>/udp/<port>/quic-v1`.
