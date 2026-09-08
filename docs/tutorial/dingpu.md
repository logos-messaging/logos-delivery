# Dingpu testnet

> TODO (2023-05-24): Deprecate or fix

*NOTE: Some of these addresses might change. To get the latest, please see `curl -s https://fleets.status.im | jq '.fleets["waku.test"]'`*

## Basic chat usage

> If historical messaging is desired, the chat app requires that the remote peer specified in `storenode` option supports the WakuStore protocol. For the current cluster node deployed as part of Dingpu this is already the case.

Start two chat apps:

```
./build/chat2 --ports-shift:0 --storenode:/ip4/178.128.141.171/tcp/60000/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W --staticnode:/ip4/178.128.141.171/tcp/60000/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W
./build/chat2 --ports-shift:1 --storenode:/ip4/178.128.141.171/tcp/60000/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W --staticnode:/ip4/178.128.141.171/tcp/60000/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W
```

By specifying `staticnode` it connects to that node subscribes to the `waku` topic. This ensures messages are relayed properly.

Then type messages to publish.

## Interactively add a node

There is also an interactive mode. Type `/connect` then paste address of other node. However, this currently has some timing issues with mesh not being updated, so it is advised not to use this until this has been addressed. See https://github.com/waku-org/nwaku/issues/231

## Dingpu cluster node

> TODO (2024-03-11): Fix node multiaddr

## Run a node

To just run a node and not interact on the chat it is enough to run `logosdeliverynode`:
```
./build/logosdeliverynode --staticnode:<multiaddr>
```

You can also run the `wakubridge` process, which runs both a Waku v1 and Waku v2
node. Currently, it has the same effect as running a `wakunode` and `logosdeliverynode`
process separately, but bridging functionality will be added later to this
application.

```
./build/wakubridge --staticnodev2:<multiaddr> --fleetv1:test
```
