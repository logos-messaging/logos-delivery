# Running Filter Protocol

> TODO (2023-05-24): Deprecate or fix

## How to

Build:

```
# make logosdeliverynode is run as part of scripts2 target
make scripts2
```

Run two nodes and connect them:

```
# Starts listening on 60000 with RPC server on 8545.
# Note the "listening on address" in logs.
./build/logosdeliverynode --ports-shift:0

# Run another node with staticnode argument
./build/logosdeliverynode --ports-shift:1 --staticnode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp --filternode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp
```

You should see your nodes connecting.

Do basic RPC calls:

```
./build/rpc_subscribe 8545
./build/rpc_subscribe_filter 8546 # enter your content topic; default is "1"
./build/rpc_publish 8545 # enter your message in STDIN
```

You should see other node receive something.
