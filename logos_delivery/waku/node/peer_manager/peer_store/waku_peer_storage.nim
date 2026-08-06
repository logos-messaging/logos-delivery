{.push raises: [].}

import std/sets, results, sqlite3_abi, eth/p2p/discoveryv5/enr
import protobuf_serialization, protobuf_serialization/pkg/results
import libp2p/[peerid, multiaddress, crypto/crypto]
import
  ../../../common/databases/db_sqlite,
  ../../../common/protobuf,
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

type RemotePeerInfoPB {.proto2.} = object
  peerId {.fieldNumber: 1, ext, required.}: PeerId
  addrs {.fieldNumber: 2, ext.}: seq[MultiAddress]
  protocols {.fieldNumber: 3.}: seq[string]
  publicKey {.fieldNumber: 4, required.}: seq[byte]
  connectedness {.fieldNumber: 5, pint.}: Opt[uint32]
  disconnectTime {.fieldNumber: 6, pint.}: Opt[uint64]
  enr {.fieldNumber: 7.}: Opt[seq[byte]]

proc decodeRemotePeerInfo(buffer: seq[byte]): ProtobufResult[RemotePeerInfo] =
  var pb: RemotePeerInfoPB
  try:
    pb = Protobuf.decode(buffer, RemotePeerInfoPB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  var storedInfo = RemotePeerInfo()
  storedInfo.peerId = pb.peerId
  storedInfo.addrs = pb.addrs
  storedInfo.protocols = pb.protocols

  var publicKey: crypto.PublicKey
  if publicKey.init(pb.publicKey):
    storedInfo.publicKey = publicKey

  storedInfo.connectedness = Connectedness(pb.connectedness.get(0'u32))
  storedInfo.disconnectTime = int64(pb.disconnectTime.get(0'u64))

  if pb.enr.isSome():
    var record: Record
    if record.fromBytes(pb.enr.get()):
      storedInfo.enr = Opt.some(record)

  ok(storedInfo)

proc decode*(T: type RemotePeerInfo, buffer: seq[byte]): ProtobufResult[T] =
  decodeRemotePeerInfo(buffer)

proc encode*(remotePeerInfo: RemotePeerInfo): PeerStorageResult[seq[byte]] =
  let publicKeyBytes = remotePeerInfo.publicKey.getBytes().valueOr:
    return err("Encoding public key failed: " & $error)

  let enr =
    if remotePeerInfo.enr.isSome():
      Opt.some(remotePeerInfo.enr.get().raw)
    else:
      Opt.none(seq[byte])

  ok(
    Protobuf.encode(
      RemotePeerInfoPB(
        peerId: remotePeerInfo.peerId,
        addrs: remotePeerInfo.addrs,
        protocols: remotePeerInfo.protocols,
        publicKey: publicKeyBytes,
        connectedness: Opt.some(uint32(ord(remotePeerInfo.connectedness))),
        disconnectTime: Opt.some(uint64(remotePeerInfo.disconnectTime)),
        enr: enr,
      )
    )
  )

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

  db.replaceStmt.exec((remotePeerInfo.peerId.data, encoded)).isOkOr:
    return err("DB operation failed: " & error)

  return ok()

method getAll*(
    db: WakuPeerStorage, onData: peer_storage.DataProc
): PeerStorageResult[void] =
  ## Retrieves all peers from storage

  proc peer(
      s: ptr sqlite3_stmt
  ) {.gcsafe, raises: [ResultError[protobuf.ProtobufError]].} =
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
