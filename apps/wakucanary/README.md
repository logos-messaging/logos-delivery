# waku canary tool

Attempts to dial a peer and asserts it supports a given set of protocols.

```console
./build/wakucanary --help
Usage:

wakucanary [OPTIONS]...

The following options are available:

 -a, --address        Multiaddress of the peer node to attempt to dial.
 -t, --timeout        Timeout to consider that the connection failed [=chronos.seconds(10)].
 -p, --protocol       Protocol required to be supported: store,storev3,relay,lightpush,filter,
                      peer-exchange,store-sync,mix,... (can be used multiple times).
 -l, --log-level      Sets the log level [=LogLevel.DEBUG].
 -np, --node-port     Listening port for waku node [=60000].
     --websocket-secure-key-path  Secure websocket key path:   '/path/to/key.txt' .
     --websocket-secure-cert-path  Secure websocket Certificate path:   '/path/to/cert.txt' .
 -c, --cluster-id     Cluster ID of the fleet node to check status [Default=1]
 -s, --shard         Shards index to subscribe to topics [ Argument may be repeated ]

```

Supported `--protocol` values. A protocol is reported as supported when the peer
advertises (via identify) a protocol id starting with the given prefix.

| `--protocol`    | Protocol id prefix               |
| --------------- | -------------------------------- |
| `relay`         | `/vac/waku/relay/`               |
| `store`         | `/vac/waku/store/`               |
| `storev3`       | `/vac/waku/store-query/3`        |
| `store-sync`    | `/vac/waku/reconciliation/`      |
| `lightpush`     | `/vac/waku/lightpush/`           |
| `filter`        | `/vac/waku/filter-subscribe/2`   |
| `filter-push`   | `/vac/waku/filter-push/`         |
| `peer-exchange` | `/vac/waku/peer-exchange/`       |
| `metadata`      | `/vac/waku/metadata/`            |
| `mix`           | `/mix/1.`                        |
| `rendezvous`    | `/rendezvous/`                   |
| `ipfs-id`       | `/ipfs/id/`                      |
| `ipfs-ping`     | `/ipfs/ping/`                    |
| `autonat`       | `/libp2p/autonat/`               |
| `circuit-relay` | `/libp2p/circuit/relay/`         |

RLN relay is not a separate libp2p protocol (it validates messages inside relay)
and is not advertised in the ENR, so it can't be checked by the canary.

The tool can be built as:

```console
$ make wakucanary
```

And used as follows. A reachable node that supports both `store` and `filter` protocols.

```console
$ ./build/wakucanary \
  --address=/dns4/store-01.do-ams3.status.staging.status.im/tcp/30303/p2p/16Uiu2HAm3xVDaz6SRJ6kErwC21zBJEZjavVXg7VSkoWzaV1aMA3F \
  --protocol=store \
  --protocol=filter \
  --cluster-id=16 \
  --shard=64
$ echo $?
0
```

A node that supports peer exchange, store sync and mix.

```console
$ ./build/wakucanary \
  --address=/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAm... \
  --protocol=peer-exchange \
  --protocol=store-sync \
  --protocol=mix \
  --cluster-id=1
$ echo $?
0
```

A node that can't be reached.
```console
$ ./build/wakucanary \
  --address=/dns4/store-01.do-ams3.status.staging.status.im/tcp/1000/p2p/16Uiu2HAm3xVDaz6SRJ6kErwC21zBJEZjavVXg7VSkoWzaV1aMA3F \
  --protocol=store \
  --protocol=filter \
  --cluster-id=16 \
  --shard=64
$ echo $?
1
```

Note that a domain name can also be used.
```console
--- not defined yet 
$ echo $?
0
```

Websockets are also supported. The websocket port openned by waku canary is calculated as `$(--node-port) + 1000` (e.g. when you set `-np 60000`, the WS port will be `61000`)
```console
$ ./build/wakucanary --address=/ip4/127.0.0.1/tcp/7777/ws/p2p/16Uiu2HAm4ng2DaLPniRoZtMQbLdjYYWnXjrrJkGoXWCoBWAdn1tu --protocol=store --protocol=filter
$ ./build/wakucanary --address=/ip4/127.0.0.1/tcp/7777/wss/p2p/16Uiu2HAmB6JQpewXScGoQ2syqmimbe4GviLxRwfsR8dCpwaGBPSE --protocol=store --websocket-secure-key-path=MyKey.key --websocket-secure-cert-path=MyCertificate.crt
```
