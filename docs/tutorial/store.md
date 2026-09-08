# Running Store Protocol

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
./build/logosdeliverynode --ports-shift:1 --staticnode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp --storenode:/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmF4tuht6fmna6uDqoSMgFqhUrdaVR6VQRyGr6sCpfS2jp
```

When flag `persist-messages` is passed messages are going to be persisted in-memory. 
If additionally flag `dbpath` is passed with a path, messages are persisted and stored in a database called `store` under the specified path. 
If flag `persist-messages` is not passed, messages are not persisted and stored at all.



You should see your nodes connecting.

Do basic RPC calls:

```
./build/rpc_subscribe 8545
./build/rpc_subscribe 8546
./build/rpc_publish 8545 # enter your message in STDIN
./build/rpc_query 8546 # enter your content topic; default is "1"
```

You should see other node receive something.
