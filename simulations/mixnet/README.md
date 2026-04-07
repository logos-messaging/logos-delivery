# Mixnet simulation

## Aim

Simulate a local mixnet along with a chat app to publish using mix.
This is helpful to test any changes during development.

## Simulation Details

The simulation includes:

1. A 5-node mixnet where `run_mix_node.sh` is the bootstrap node for the other 4 nodes
2. Two chat app instances that publish messages using lightpush protocol over the mixnet

### Available Scripts

| Script             | Description                                |
| ------------------ | ------------------------------------------ |
| `run_mix_node.sh`  | Bootstrap mix node (must be started first) |
| `run_mix_node1.sh` | Mix node 1                                 |
| `run_mix_node2.sh` | Mix node 2                                 |
| `run_mix_node3.sh` | Mix node 3                                 |
| `run_mix_node4.sh` | Mix node 4                                 |
| `run_chat_mix.sh`  | Chat app instance 1                        |
| `run_chat_mix1.sh` | Chat app instance 2                        |
| `build_setup.sh`   | Build and generate RLN credentials         |

## Prerequisites

Before running the simulation, build `wakunode2` and `chat2mix`:

```bash
cd <repo-root-dir>
source env.sh
make wakunode2 chat2mix
```

## RLN Spam Protection Setup

Generate RLN credentials and the shared Merkle tree for all nodes:

```bash
cd simulations/mixnet
./build_setup.sh
```

This script will:

1. Build and run the `setup_credentials` tool
2. Generate RLN credentials for all nodes (5 mix nodes + 2 chat clients)
3. Create `rln_tree.db` - the shared Merkle tree with all members
4. Create keystore files (`rln_keystore_{peerId}.json`) for each node

**Important:** All scripts must be run from this directory (`simulations/mixnet/`) so they can access their credentials and tree file.

To regenerate credentials (e.g., after adding new nodes), run `./build_setup.sh` again - it will clean up old files first.

## Usage

### Step 1: Start the Mix Nodes

Start the bootstrap node first (in a separate terminal):

```bash
./run_mix_node.sh
```

Look for the following log lines to ensure the node started successfully:

```log
INF mounting mix protocol                      topics="waku node"
INF Node setup complete                        topics="wakunode main"
```

Verify RLN spam protection initialized correctly by checking for these logs:

```log
INF Initializing MixRlnSpamProtection
INF MixRlnSpamProtection initialized, waiting for sync
DBG Tree loaded from file
INF MixRlnSpamProtection started
```

Then start the remaining mix nodes in separate terminals:

```bash
./run_mix_node1.sh
./run_mix_node2.sh
./run_mix_node3.sh
./run_mix_node4.sh
```

### Step 2: Start the Chat Applications

Once all 5 mix nodes are running, start the first chat app:

```bash
./run_chat_mix.sh
```

Enter a nickname when prompted:

```bash
pubsub topic is: /waku/2/rs/2/0
Choose a nickname >>
```

Once you see the following log, the app is ready to publish messages over the mixnet:

```bash
Welcome, test!
Listening on
 /ip4/<local-network-ip>/tcp/60000/p2p/16Uiu2HAkxDGqix1ifY3wF1ZzojQWRAQEdKP75wn1LJMfoHhfHz57
ready to publish messages now
```

Start the second chat app in another terminal:

```bash
./run_chat_mix1.sh
```

### Step 3: Test Messaging

Once both chat apps are running, send a message from one and verify it is received by the other.

To exit the chat apps, enter `/exit`:

```bash
>> /exit
quitting...
```
