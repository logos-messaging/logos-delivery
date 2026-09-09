# Using the `chat2` application

## Background

The `chat2` application is a basic command-line chat app using the [Waku v2 suite of protocols](https://rfc.vac.dev/).
It optionally connects to a [fleet of nodes](fleets.status.im) to provide end-to-end p2p chat capabilities.
Each fleet is a publicly accessible network of Waku v2 peers, providing a bootstrap connection point for new peers, historical message storage, etc.
The Waku team is currently using this application on the _sandbox_ fleet for internal testing.
For more information on the available fleets, see [`Connecting to a Waku v2 fleet`](#connecting-to-a-waku-v2-fleet).
If you want to try our protocols, or join the dogfooding fun, follow the instructions below.

## Preparation

Ensure you have cloned the `nim-waku` repository and installed all prerequisites as per [these instructions](https://github.com/status-im/nim-waku).

Make the `chat2` target.

```
make chat2
```

## Basic application usage

To start the `chat2` application in its most basic form, run the following from the project directory

```
./build/chat2
```

You should be prompted to provide a nickname for the chat session.

```
Choose a nickname >>
```

After entering a nickname, the app will randomly select and connect to a peer from the `sandbox` fleet.

```
No static peers configured. Choosing one at random from sandbox fleet...
```

It will then attempt to download historical messages from a random peer in the `sandbox` fleet.

```
Store enabled, but no store nodes configured. Choosing one at random from sandbox fleet...
```

Wait for the chat prompt (`>>`) and chat away!

To gracefully exit the `chat2` application, use the `/exit` [in-chat option](#in-chat-options)

```
>> /exit
quitting...
```

## Retrieving historical messages

The `chat2` application can retrieve historical chat messages from a node supporting and running the [Waku v2 store protocol](https://rfc.vac.dev/spec/13/), and will attempt to do so by default.
It's possible to query a *specific* store node by configuring its `multiaddr` as `storenode` when starting the app:

```
./build/chat2 --storenode:/dns4/node-01.do-ams3.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W
```

Alternatively, the `chat2` application will select a random `storenode` for you from the configured fleet (`sandbox` by default) if `storenode` is left unspecified.

```
./build/chat2
```

To disable historical message retrieval, use the `--store:false` option:

```
./build/chat2 --store:false
```

## Specifying a static peer

In order to connect to a *specific* node as [`relay`](https://rfc.vac.dev/spec/11/) peer, define that node's `multiaddr` as a `staticnode` when starting the app:

```
./build/chat2 --staticnode:/dns4/node-01.do-ams3.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W
```

This will bypass the random peer selection process and connect to the specified node.

## Connecting to a Waku v2 fleet

It is possible to specify a specific Waku v2 fleet to connect to when starting the app by using the `--fleet` option:

```
./build/chat2 --fleet:test
```

There are currently two fleets to select from, namely _sandbox_ (`waku.sandbox`) and _test_ (`waku.test`).
The `test` fleet is updated with each incremental change to the `nim-waku` codebase.
As a result it may have more advanced and experimental features, but will be less stable than `sandbox`.
The `sandbox` fleet is a deployed network of the latest released Waku v2 nodes.
If no `fleet` is specified, `chat2` will connect to the `sandbox` fleet by default.
To start `chat2` without connecting to a fleet, use the `--fleet:none` option _or_ [specify a static peer](#specifying-a-static-peer).

## Specifying a content topic

To publish chat messages on a specific [content topic](https://rfc.vac.dev/spec/14/#wakumessage), use the `--content-topic` option:

```
./build/chat2 --content-topic:/waku/2/my-content-topic/proto
```

> **NOTE:** Currently (2021/05/26) the content topic defaults to `/waku/2/huilong/proto` if left unspecified, where `huilong` is the name of our latest testnet.

## In-chat options

| Command | Effect |
| --- | --- |
| `/help` | displays available in-chat commands |
| `/connect` | interactively connect to a new peer |
| `/nick` | change nickname for current chat session |
| `/exit` | exits the current chat session |

## `chat2` message protobuf format

Each `chat2` message is encoded as follows

```protobuf
message Chat2Message {
  uint64 timestamp = 1;
  string nick = 2;
  bytes payload = 3;
}
```

where `timestamp` is the Unix timestamp of the message, `nick` is the relevant `chat2` user's selected nickname and `payload` is the actual chat message being sent.
The `payload` is the byte array representation of a UTF8 encoded string.

# Bridge messages between `chat2` and matterbridge

To facilitate `chat2` use in a variety of contexts, a `chat2bridge` can be deployed to bridge messages between `chat2` and any protocol supported by matterbridge.

## Configure and run matterbridge

1. Download and install [matterbridge](https://github.com/42wim/matterbridge) and configure an instance for the protocol(s) you want to bridge to.
Basic configuration instructions [here](https://github.com/42wim/matterbridge/wiki/How-to-create-your-config)
2. Configure the matterbridge API.
This is used by the `chat2bridge` to relay `chat2` messages to and from matterbridge.
Configuration instructions for the matterbridge API can be found [here](https://github.com/42wim/matterbridge/wiki/Api).
The full matterbridge API specification can be found [here](https://app.swaggerhub.com/apis-docs/matterbridge/matterbridge-api/0.1.0-oas3).
The template below shows an example of a `matterbridge.toml` configuration file for bridging `chat2` to Discord.
Follow the matterbridge [Discord instructions](https://github.com/42wim/matterbridge/wiki/Section-Discord-%28basic%29) to configure your own `Token` and `Server`.
```toml
[discord.mydiscord]

# You can get your token by following the instructions on
# https://github.com/42wim/matterbridge/wiki/Discord-bot-setup.
# If you want roles/groups mentions to be shown with names instead of ID,
# you'll need to give your bot the "Manage Roles" permission.
Token="MTk4NjIyNDgzNDcdOTI1MjQ4.Cl2FMZ.ZnCjm1XVW7vRze4b7Cq4se7kKWs-abD"

Server="myserver" # picked from guilds the bot is connected to

RemoteNickFormat="{NICK}@chat2: "

[api.myapi]
BindAddress="127.0.0.1:4242"
Buffer=1000
RemoteNickFormat="{NICK}@{PROTOCOL}"

[[gateway]]
name="gateway1"
enable=true

[[gateway.inout]]
account="discord.mydiscord"
channel="general"

[[gateway.inout]]
account="api.myapi"
channel="api"
```
3. Run matterbridge using the configuration file created in the previous step.
Note the API listening address and port in the matterbridge logs (configured as the `BindAddress` in the previous step).
```
./matterbridge -conf matterbridge.toml
```
```
[0000]  INFO api:          Listening on 127.0.0.1:4242
```
## Configure and run `chat2bridge`
1. From the `nim-waku` project directory, make the `chat2bridge` target
```
make chat2bridge
```
2. Run `chat2bridge` with the following configuration options:
```
--mb-host-address         Listening address of the Matterbridge host
--mb-host-port            Listening port of the Matterbridge host
--mb-gateway              Matterbridge gateway
```
```
./build/chat2bridge --mb-host-address=127.0.0.1 --mb-host-port=4242 --mb-gateway="gateway1"
```
Note that `chat2bridge` encompasses a full `logosdeliverynode` which can be configured with the normal configuration parameters.
For a full list of configuration options, run `--help`.
```
./build/chat2bridge --help
```
## Connect `chat2bridge` to a `chat2` network
1. To bridge messages on an existing `chat2` network, connect to any relay peer(s) in that network from `chat2bridge`.
This can be done by either specifying the peer(s) as a `--staticnode` when starting the `chat2bridge` or calling the [`post_waku_v2_admin_v1_peers`](https://rfc.vac.dev/spec/16/#post_waku_v2_admin_v1_peers) method on the JSON-RPC API.
Note that the latter requires the `chat2bridge` to be run with `--rpc=true` and `--rpc-admin=true`.
1. To bridge from a new `chat2` instance, simply specify the `chat2bridge` listening address as a `chat2` [static peer](#Specifying-a-static-peer).
