import results, testutils/unittests

import waku/node/peer_manager/peer_store/peer_storage, waku/waku_core/peers

suite "PeerStorage":
  var peerStorage {.threadvar.}: PeerStorage

  setup:
    peerStorage = PeerStorage()

  suite "put":
    test "unimplemented":
      check:
        peerStorage.put(nil) == PeerStorageResult[void].err("Unimplemented")

  suite "getAll":
    test "unimplemented":
      let emptyClosure = proc(remotePeerInfo: RemotePeerInfo) =
        discard
      check:
        peerStorage.getAll(emptyClosure) == PeerStorageResult[void].err("Unimplemented")
