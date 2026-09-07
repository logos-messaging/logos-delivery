## App description
This is a very simple example that shows how to invoke libwaku functions from a C program.

## Build
1. Open terminal
2. cd to nwaku root folder
3. make cwaku_example -j8

This will create liblogosdelivery.so and cwaku_example binary within the build folder.

## Run
1. Open terminal
2. cd to nwaku root folder
3. export LD_LIBRARY_PATH=build
4. `./build/cwaku_example -h 0.0.0.0 -p 60001`

Options are short flags: `-h <host> -p <tcp-port> -k <key> -r <relay> -a <peers>`.
The discv5 UDP port is derived as `-p` + 1, so two local instances do not clash.

## Menu option 4: a segmented send

Option 4 sends a payload one byte past three whole segments over a reliable
channel, so the segmentation layer has to split it into four.

### Confirming the split

Run one node, pick option 4, and count the distinct messages it put on the
channel's content topic:

```
./build/cwaku_example -h 127.0.0.1 -p 60000 > run.log 2>&1
# pick option 4, then:
grep large-message run.log | grep -oE '0x[0-9a-f]{64}' | sort -u | wc -l
```

One send must yield `CHANNEL_DATA_SEGMENTS` (4) hashes. That is the whole point
of the option: fewer means the payload was not split.

### Two instances

Start a second node on another port, then on the sender use option 2 with the
receiver's `/ip4/.../tcp/<port>/p2p/<peer-id>` (printed at startup) before
option 4. Each instance derives its own channel sender id from its TCP port,
because SDS ignores messages whose sender id matches its own participant id.

Observed so far: the four segments do reach the peer, which reports four
`message_received` events carrying the `RELIABLE-CHANNEL-API/1` marker on the
channel's content topic. Reassembly into a single `onChannelMessageReceived`
has **not** been observed on the receiver in a local two-node run, with no
error event and no output from the segmentation layer, so treat the receive
half as unverified.
