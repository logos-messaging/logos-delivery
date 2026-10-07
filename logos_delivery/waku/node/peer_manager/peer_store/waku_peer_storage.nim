{.push raises: [].}

import std/sets, chronicles, results, sqlite3_abi, stew/byteutils
import
  ../../../common/databases/db_sqlite,
  ../../../common/protobuf,
  ../../../waku_core,
  ../waku_peer_store,
  ./peer_storage

export db_sqlite

logScope:
  topics = "waku node peer_manager"

type WakuPeerStorage* = ref object of PeerStorage
  database*: SqliteDatabase
  replaceStmt: SqliteStmt[(seq[byte], seq[byte]), void]
  deleteStmt: SqliteStmt[seq[byte], void]

##########################
# Protobuf Serialisation #
##########################

# `RemotePeerInfo` is a `ref object`. The library encodes only an `object`,
# so these procs use the object that the ref points to.

proc decodeRemotePeerInfo(buffer: seq[byte]): ProtobufResult[RemotePeerInfo] =
  var storedInfo = RemotePeerInfo()
  try:
    storedInfo[] = Protobuf.decode(buffer, typeof(storedInfo[]))
  except SerializationError as e:
    return err(ProtobufError.decodeFailure(e.msg))
  ok(storedInfo)

# `decode` is generic. It calls a proc that is not generic, as `protobufCodec`
# does, so a caller needs no import of the library.
proc decode*(T: type RemotePeerInfo, buffer: seq[byte]): ProtobufResult[T] =
  decodeRemotePeerInfo(buffer)

proc encode*(remotePeerInfo: RemotePeerInfo): PeerStorageResult[seq[byte]] =
  # The `PublicKey` extension of libp2p raises a `Defect` on an empty key.
  # A peer from an ENR or from a multiaddress has no key until it connects.
  remotePeerInfo.publicKey.getBytes().isOkOr:
    return err("Encoding public key failed: " & $error)
  ok(Protobuf.encode(remotePeerInfo[]))

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

  let deleteStmt = db
    .prepareStmt("DELETE FROM Peer WHERE peerId = ?;", seq[byte], void)
    .expect("Valid statement")

  # General initialization
  let ps =
    WakuPeerStorage(database: db, replaceStmt: replaceStmt, deleteStmt: deleteStmt)

  return ok(ps)

method put*(
    db: WakuPeerStorage, remotePeerInfo: RemotePeerInfo
): PeerStorageResult[void] {.gcsafe.} =
  ## Adds a peer to storage or replaces existing entry if it already exists

  let encoded = remotePeerInfo.encode().valueOr:
    return err("peer info encoding failed: " & error)

  db.replaceStmt.exec((remotePeerInfo.peerId.data, encoded)).isOkOr:
    return err("DB operation failed: " & error)

  return ok()

proc peerIdText(data: seq[byte]): string =
  ## The peer id of a row as text for a log line, or its bytes in hex.
  let peerId = PeerId.init(data).valueOr:
    return byteutils.toHex(data)
  $peerId

method getAll*(
    db: WakuPeerStorage, onData: peer_storage.DataProc
): PeerStorageResult[void] =
  ## Retrieves all peers from storage. It deletes a row that does not decode,
  ## and it loads the other rows.

  var undecodable: seq[seq[byte]]

  proc peer(s: ptr sqlite3_stmt) {.gcsafe, raises: [].} =
    let
      # Stored Info
      sTo = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 1))
      sToL = sqlite3_column_bytes(s, 1)
    # A row that an older version wrote can have a value that this version
    # refuses.
    let storedInfo = RemotePeerInfo.decode(@(toOpenArray(sTo, 0, sToL - 1))).valueOr:
      let
        sId = cast[ptr UncheckedArray[byte]](sqlite3_column_blob(s, 0))
        sIdL = sqlite3_column_bytes(s, 0)
        peerId = @(toOpenArray(sId, 0, sIdL - 1))
      info "Deleting a stored peer that does not decode",
        peerId = peerIdText(peerId), error = $error
      undecodable.add(peerId)
      return

    onData(storedInfo)

  let catchRes = catch:
    db.database.query("SELECT peerId, storedInfo FROM Peer", peer)

  let queryRes = catchRes.valueOr:
    return err("failed to extract peer from query result: " & catchRes.error.msg)

  queryRes.isOkOr:
    return err("peer storage query failed: " & error)

  for peerId in undecodable:
    db.deleteStmt.exec(peerId).isOkOr:
      return err("failed to delete a stored peer: " & error)

  return ok()

proc close*(db: WakuPeerStorage) =
  ## Closes the database.

  db.replaceStmt.dispose()
  db.deleteStmt.dispose()
  db.database.close()
