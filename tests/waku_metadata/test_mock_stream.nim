{.used.}

## Runs the metadata protocol over an in-memory stream: any type satisfying
## `IStream` can carry a protocol, no nim-libp2p transport is involved.

import
  std/sequtils, results, testutils/unittests, chronos, chronicles, libp2p/crypto/crypto

import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_metadata,
  logos_delivery/waku/libp2p_iface/stream

type MockStream = ref object
  peerId: PeerId
  inbox: AsyncQueue[seq[byte]]
  peer: MockStream
  closed: bool

proc newMockPair(): tuple[a, b: MockStream] =
  let rng = newRng()
  let a =
    MockStream(peerId: PeerId.random(rng).get(), inbox: newAsyncQueue[seq[byte]]())
  let b =
    MockStream(peerId: PeerId.random(rng).get(), inbox: newAsyncQueue[seq[byte]]())
  a.peer = b
  b.peer = a
  return (a, b)

proc writeLP(s: MockStream, data: seq[byte]): Future[void] {.async.} =
  await s.peer.inbox.put(data)

proc readLp(s: MockStream, maxSize: int): Future[seq[byte]] {.async.} =
  return await s.inbox.get()

proc close(s: MockStream): Future[void] {.async: (raises: [CancelledError]).} =
  s.closed = true

proc atEof(s: MockStream): bool =
  return s.closed

proc closeWithEof(s: MockStream): Future[void] {.async: (raises: [CancelledError]).} =
  s.closed = true

static:
  doAssert MockStream is IStream

suite "Waku Metadata - mock stream":
  asyncTest "request() gets the cluster and shards served by the remote handler":
    let
      server = WakuMetadata.new(
        7,
        proc(): seq[uint16] {.gcsafe, raises: [].} =
          @[1'u16, 2'u16],
      )
      client = WakuMetadata.new(
        7,
        proc(): seq[uint16] {.gcsafe, raises: [].} =
          @[],
      )
      (clientEnd, serverEnd) = newMockPair()

    let serving = server.handleStream(serverEnd, WakuMetadataCodec)
    let response = (await client.request(clientEnd)).tryGet()
    await serving

    check:
      response.clusterId == Opt.some(7'u32)
      response.shards == @[1'u32, 2'u32]
      clientEnd.closed
      serverEnd.closed
