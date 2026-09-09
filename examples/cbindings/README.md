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

### Confirming the reassembly

This needs two nodes, and each must run **from its own directory**:

```
mkdir -p /tmp/nodeA /tmp/nodeB
(cd /tmp/nodeB && <repo>/build/cwaku_example -h 127.0.0.1 -p 60141)
(cd /tmp/nodeA && <repo>/build/cwaku_example -h 127.0.0.1 -p 60142)
```

On the sender, use option 2 with the receiver's
`/ip4/.../tcp/<port>/p2p/<peer-id>` (printed at startup), then option 4. The
receiver reports a single `onChannelMessageReceived` carrying the whole
payload, not one event per segment.

The separate directories matter. A node persists its SDS state in
`store.sqlite3` in the working directory, and that state includes the message
ids it has already seen. Two nodes started from the same directory share one
store, so the receiver treats the sender's segments as duplicates it has
already handled and drops all of them: four segments arrive, nothing is
reassembled, and nothing is logged, because a duplicate is a silent outcome by
design.

For the same reason each send seeds its payload from the clock. An identical
payload produces identical SDS message ids, so a receiver that saw the previous
run would discard the next one as a replay.
