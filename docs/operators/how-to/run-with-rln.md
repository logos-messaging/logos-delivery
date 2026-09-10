# How to run spam prevention on your nwaku node (RLN)

This guide explains how to run a nwaku node with RLN (Rate Limiting Nullifier) enabled.

[RLN](https://rfc.vac.dev/spec/32/) is a protocol integrated into waku v2,
which prevents spam-based attacks on the network.

For further background on the research for RLN tailored to waku, refer
to [this](https://rfc.vac.dev/spec/17/) RFC.

Registering to the membership group has been left out for brevity.
If you would like to register to the membership group and send messages with RLN,
refer to the [on-chain chat2 tutorial](../../tutorial/onchain-rln-relay-chat2.md).

This guide specifically allows a node to participate in RLN testnet 2.
You may alter the rln-specific arguments as required.

## Prerequisites

1. Follow the [droplet quickstart](../droplet-quickstart.md) or the [build guide](./build.md) till the `make` command for the logosdeliverynode binary.

> Note: If you would like to run a nwaku node with RLN enabled within a docker container, skip ahead to step 2.

## 1. Build logosdeliverynode

Run -
```bash
make logosdeliverynode
```

## 2. Update the runtime arguments

Follow [Step 10](../droplet-quickstart.md#10-run-nwaku) of the [droplet quickstart](../droplet-quickstart.md) guide, while replacing the run command with -

```bash
export LINEA_SEPOLIA_HTTP_NODE_ADDRESS=<HTTP RPC URL to a Linea Sepolia Node>
export RLN_RELAY_CONTRACT_ADDRESS="0xB9cd878C90E49F797B4431fBF4fb333108CB90e6" # Replace this with any compatible implementation
$WAKUNODE_DIR/logosdeliverynode \
--store:true \
--dns-discovery \
--dns-discovery-url:"$WAKU_FLEET" \
--discv5-discovery:true \
--rln-relay:true \
--rln-relay-dynamic:true \
--rln-relay-eth-contract-address:"$RLN_RELAY_CONTRACT_ADDRESS" \
--rln-relay-eth-client-address:"$LINEA_SEPOLIA_HTTP_NODE_ADDRESS"
```

OR

If you are running the nwaku node within docker, follow [Step 2](../docker-quickstart.md#step-2-run) while replacing the run command with -

```bash
export WAKU_FLEET=<entree of the fleet>
export LINEA_SEPOLIA_HTTP_NODE_ADDRESS=<HTTP RPC URL to a Sepolia Node>
export RLN_RELAY_CONTRACT_ADDRESS="0xB9cd878C90E49F797B4431fBF4fb333108CB90e6" # Replace this with any compatible implementation
docker run -i -t -p 60000:60000 -p 9000:9000/udp wakuorg/nwaku:v0.36.0 \
  --dns-discovery:true \
  --dns-discovery-url:"$WAKU_FLEET" \
  --discv5-discovery \
  --nat:extip:[yourpublicip] \ # or, if you are behind a nat: --nat=any
  --rln-relay:true \
  --rln-relay-dynamic:true \
  --rln-relay-eth-contract-address:"$RLN_RELAY_CONTRACT_ADDRESS" \
  --rln-relay-eth-client-address:"$LINEA_SEPOLIA_HTTP_NODE_ADDRESS"
```

> Note: You can choose to keep connections to other nodes alive by adding the `--keep-alive` flag.

Following is the list of additional fields that have been added to the
runtime arguments -

1. `--rln-relay`: Allows waku-rln-relay to be mounted into the setup of the nwaku node
2. `--rln-relay-dynamic`: Enables waku-rln-relay to connect to an ethereum node to fetch the membership group
3. `--rln-relay-eth-contract-address`: The contract address of an RLN membership group
4. `--rln-relay-eth-client-address`: The HTTP url to a Linea Sepolia ethereum node

You should now have nwaku running, with RLN enabled!

To see metrics related to the functioning of RLN, refer to this [guide](./todo).
You can also refer to the periodic logging, for a few metrics like -

- number of spam messages
- number of valid messages
- number of invalid messages


> Note: This guide will be updated in the future to include features like slashing.
