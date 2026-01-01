{.push raises: [].}

import
  std/[sets, options],
  results,
  sqlite3_abi,
  eth/enr/enr,
  libp2p/protobuf/minprotobuf
import
  ../../../common/databases/db_sqlite,
  ../../../waku_core,
  ../waku_peer_store,
  ./peer_storage

export db_sqlite

type WakuPeerStorage* = ref object of PeerStorage
  database*: SqliteDatabase
  replaceStmt: SqliteStmt[(seq[byte], seq[byte]), void]

##########################
# Protobuf Serialisation #
##########################

proc decode*(T: type RemotePeerInfo, buffer: seq[byte]): ProtoResult[T] =
  var
    multiaddrSeq: seq[MultiAddress]
    protoSeq: seq[string]
    storedInfo = RemotePeerInfo()
    rlpBytes: seq[byte]
    connectedness: uint32
    disconnectTime: uint64

  var pb = initProtoBuffer(buffer)

  discard ?pb.getField(1, storedInfo.peerId)
  discard ?pb.getRepeatedField(2, multiaddrSeq)
  discard ?pb.getRepeatedField(3, protoSeq)
  discard ?pb.getField(4, storedInfo.publicKey)
  discard ?pb.getField(5, connectedness)
  discard ?pb.getField(6, disconnectTime)
  let hasENR = ?pb.getField(7, rlpBytes)

  storedInfo.addrs = multiaddrSeq
  storedInfo.protocols = protoSeq
  storedInfo.connectedness = Connectedness(connectedness)
  storedInfo.disconnectTime = int64(disconnectTime)

  if hasENR:
    var record: Record

    if record.fromBytes(rlpBytes):
      storedInfo.enr = some(record)

  ok(storedInfo)

proc encode*(remotePeerInfo: RemotePeerInfo): PeerStorageResult[ProtoBuffer] =
  var pb = initProtoBuffer()

  pb.write(1, remotePeerInfo.peerId)

  for multiaddr in remotePeerInfo.addrs.items:
    pb.write(2, multiaddr)

  for proto in remotePeerInfo.protocols.items:
    pb.write(3, proto)

  let catchRes = catch:
    pb.write(4, remotePeerInfo.publicKey)
  catchRes.isOkOr:
    return err("Enncoding public key failed: " & catchRes.error.msg)

  pb.write(5, uint32(ord(remotePeerInfo.connectedness)))

  pb.write(6, uint64(remotePeerInfo.disconnectTime))

  if remotePeerInfo.enr.isSome():
    pb.write(7, remotePeerInfo.enr.get().raw)

  return ok(pb)

##########################
# Storage implementation #
##########################

proc new*(T: type WakuPeerStorage, db: SqliteDatabase): PeerStorageResult[T] =
  # Misconfiguration can lead to nil DB
  if db.isNil():
    return err("db not initialized")

  # Create the "Peer" table
  # It contains:
  #  - peer id as primary key, stored as a blob
  #  - stored info (serialised protobuf), stored as a blob
  let createStmt = db
    .prepareStmt(
      """
    CREATE TABLE IF NOT EXISTS Peer (
        peerId BLOB PRIMARY KEY,
        storedInfo BLOB
    ) WITHOUT ROWID;
    """,
      NoParams, void,
    )
    .expect("Valid statement")

  createStmt.exec(()).isOkOr:
    return err("failed to exec")

  # We dispose of this prepared statement here, as we never use it again
  createStmt.dispose()

  # Reusable prepared statements
  let replaceStmt = db
    .prepareStmt(
      "REPLACE INTO Peer (peerId, storedInfo) VALUES (?, ?);",
      (seq[byte], seq[byte]),
      void,
    )
    .expect("Valid statement")

  # General initialization
  let ps = WakuPeerStorage(database: db, replaceStmt: replaceStmt)

  return ok(ps)

method put*(
    db: WakuPeerStorage, remotePeerInfo: RemotePeerInfo
): PeerStorageResult[void] {.gcsafe.} =
  ## Adds a peer to storage or replaces existing entry if it already exists

  let encoded = remotePeerInfo.encode().valueOr:
    return err("peer info encoding failed: " & error)

  db.replaceStmt.exec((remotePeerInfo.peerId.data, encoded.buffer)).isOkOr:
    return err("DB operation failed: " & error)

  return ok()

method getAll*(
    db: WakuPeerStorage, onData: peer_storage.DataProc
): PeerStorageResult[void] =
  ## Retrieves all peers from storage

  proc peer(s: ptr sqlite3_stmt) {.gcsafe, raises: [ResultError[ProtoError]].} =
    let
      # Stored Info
      sTo = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      sToL = sqlite3_column_bytes(s, 1)
      storedInfo = RemotePeerInfo.decode(@(toOpenArray(sTo, 0, sToL - 1))).tryGet()

    onData(storedInfo)

  let catchRes = catch:
    db.database.query("SELECT peerId, storedInfo FROM Peer", peer)

  let queryRes = catchRes.valueOr:
    return err("failed to extract peer from query result: " & catchRes.error.msg)

  queryRes.isOkOr:
    return err("peer storage query failed: " & error)

  return ok()

proc close*(db: WakuPeerStorage) =
  ## Closes the database.

  db.replaceStmt.dispose()
  db.database.close()
