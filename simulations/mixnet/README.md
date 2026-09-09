# Mixnet simulation

## Aim

Simulate a local mixnet along with a chat app to publish using mix.
This is helpful to test any changes while development.
It includes scripts that run a `4 node` mixnet along with a lightpush service node(without mix) that can be used to test quickly.

## Simulation Details

Note that before running the simulation both `logosdeliverynode` and `chat2mix` have to be built.

```bash
cd <repo-root-dir>
make logosdeliverynode
make chat2mix
```

Simulation includes scripts for:

1. a 4 waku-node mixnet where `node1` is bootstrap node for the other 3 nodes.
2. scripts to run chat app that publishes using lightpush protocol over the mixnet

## Usage

Start the service node with below command, which acts as bootstrap node for all other mix nodes.

`./run_lp_service_node.sh`

To run the nodes for mixnet run the 4 node scripts in different terminals as below.

`./run_mix_node1.sh`

Look for following 2 log lines to ensure node ran successfully and has also mounted mix protocol.

```log
INF 2025-08-01 14:51:05.445+05:30 mounting mix protocol                      topics="waku node" tid=39996871 file=waku_node.nim:231 nodeId="(listenAddresses: @[\"/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o\"], enrUri: \"enr:-NC4QKYtas8STkenlqBTJ3a1TTLzJA2DsGGbFlnxem9aSM2IXm-CSVZULdk2467bAyFnepnt8KP_QlfDzdaMXd_zqtwBgmlkgnY0gmlwhH8AAAGHbWl4LWtleaCdCc5iT3bo9gYmXtucyit96bQXcqbXhL3a-S_6j7p9LIptdWx0aWFkZHJzgIJyc4UAAgEAAIlzZWNwMjU2azGhA6RFtVJVBh0SYOoP8xrgnXSlpiFARmQkF9d8Rn4fSeiog3RjcILqYYN1ZHCCIymFd2FrdTIt\")"

INF 2025-08-01 14:49:23.467+05:30 Node setup complete                        topics="wakunode main" tid=39994244 file=logosdeliverynode.nim:104
```

Once all the 4 nodes are up without any issues, run the script to start the chat application.

`./run_chat_app.sh`

Enter a nickname to be used.

```bash
pubsub topic is: /waku/2/rs/2/0
Choose a nickname >>
```

Once you see below log, it means the app is ready for publishing messages over the mixnet.

```bash
Welcome, test!
Listening on
 /ip4/192.168.68.64/tcp/60000/p2p/16Uiu2HAkxDGqix1ifY3wF1ZzojQWRAQEdKP75wn1LJMfoHhfHz57
ready to publish messages now
```

Follow similar instructions to run second instance of chat app.
Once both the apps run successfully, send a message and check if it is received by the other app.

You can exit the chat apps by entering `/exit` as below

```bash
>> /exit
quitting...
```
