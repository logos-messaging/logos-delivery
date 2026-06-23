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
| `check_cover_traffic.sh` | Monitor cover traffic metrics from all nodes |

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

## Running Without DoS Protection

To test cover traffic without RLN spam protection (avoids heavy proof generation compute), the config files include two flags:

```toml
mix-user-message-limit=2        # slots per epoch (reduce for lighter testing)
mix-disable-spam-protection=true # skip RLN proof generation/verification
```

These are already set in `config.toml` through `config4.toml`. To re-enable RLN, set `mix-disable-spam-protection=false` (or remove the line) and ensure credentials are generated via `./build_setup.sh`.

When running without DoS protection, cover traffic uses an internal epoch timer and does not require RLN credentials or `rln_tree.db`.

### Monitoring Cover Traffic

Use the metrics script to verify cover traffic is working:

```bash
./check_cover_traffic.sh
```

Key metrics to look for:
- `mix_cover_emitted_total` — cover messages generated per node (should increase each epoch)
- `mix_cover_received_total` — cover messages received back at origin after 3-hop mix path
- `mix_slots_exhausted_total` — expected when slots per epoch are low

### Note on Rate Limit and Expected Errors

The default `mix-user-message-limit=2` (R=2) with path length L=3 yields a fractional cover target of `R/(1+L) = 0.5` packets per epoch. Because this is not an integer, epoch boundary jitter can cause two cover emissions in one epoch, exhausting all slots and leaving none for forwarding. This produces `SLOT_EXHAUSTED` and `SPAM_PROOF_GEN_FAILED` errors at intermediate hops — these are expected with the default config.

For a clean setup, R should be a multiple of `(1+L) = 4`. Setting `mix-user-message-limit=4` gives exactly 1 cover packet per epoch with 3 slots remaining for forwarding, eliminating these errors.
