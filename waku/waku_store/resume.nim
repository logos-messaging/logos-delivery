{.push raises: [].}

import
  std/options,
  sqlite3_abi,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/enr/enr

import
  ../common/databases/db_sqlite,
  ../waku_core,
  ../waku_archive,
  ../common/nimchronos,
  ../waku_store/[client, common],
  ../node/peer_manager/peer_manager

logScope:
  topics = "waku store resume"

const
  OnlineDbUrl = "lastonline.db"
  LastOnlineInterval = chronos.minutes(1)
  ResumeRangeLimit = 6 # hours

type
  TransferCallback* = proc(
    timestamp: Timestamp, peer: RemotePeerInfo
  ): Future[Result[void, string]] {.async: (raises: []), closure.}

  StoreResume* = ref object
    handle: Future[void]

    db: SqliteDatabase
    replaceStmt: SqliteStmt[(Timestamp), void]

    transferCallBack: Option[TransferCallback]

    peerManager: PeerManager

proc setupLastOnlineDB(): Result[SqliteDatabase, string] =
  let db = SqliteDatabase.new(OnlineDbUrl).valueOr:
    return err($error)

  let createStmt = db
    .prepareStmt(
      """CREATE TABLE IF NOT EXISTS last_online (timestamp BIGINT NOT NULL);""",
      NoParams, void,
    )
    .expect("Valid statement")

  createStmt.exec(()).isOkOr:
    return err("failed to exec stmt")

  # We dispose of this prepared statement here, as we never use it again
  createStmt.dispose()

  return ok(db)

proc initTransferHandler(
    self: StoreResume, wakuArchive: WakuArchive, wakuStoreClient: WakuStoreClient
) =
  # guard clauses to prevent faulty callback
  if self.peerManager.isNil():
    error "peer manager unavailable for store resume"
    return

  if wakuArchive.isNil():
    error "waku archive unavailable for store resume"
    return

  if wakuStoreClient.isNil():
    error "waku store client unavailable for store resume"
    return

  # tying archive, store client and resume into one callback and saving it for later
  self.transferCallBack = some(
    proc(
        timestamp: Timestamp, peer: RemotePeerInfo
    ): Future[Result[void, string]] {.async: (raises: []), closure.} =
      var req = StoreQueryRequest()
      req.includeData = true
      req.startTime = some(timestamp)
      req.endTime = some(getNowInNanosecondTime())
      req.paginationLimit = some(uint64(100))

      while true:
        let catchable = catch:
          await wakuStoreClient.query(req, peer)

        catchable.isOkOr:
          return err("store client error: " & error.msg)

        let res = catchable.get()
        let response = res.valueOr:
          return err("store client error: " & $error)

        req.paginationCursor = response.paginationCursor

        for kv in response.messages:
          let handleRes = catch:
            await wakuArchive.handleMessage(kv.pubsubTopic.get(), kv.message.get())

          handleRes.isOkOr:
            error "message transfer failed", error = error.msg
            continue

        if req.paginationCursor.isNone():
          break

      return ok()
  )

proc new*(
    T: type StoreResume,
    peerManager: PeerManager,
    wakuArchive: WakuArchive,
    wakuStoreClient: WakuStoreClient,
): Result[T, string] =
  info "initializing store resume"

  let db = setupLastOnlineDB().valueOr:
    return err("Failed to setup last online DB")

  let replaceStmt = db
    .prepareStmt("REPLACE INTO last_online (timestamp) VALUES (?);", (Timestamp), void)
    .expect("Valid statement")

  let resume = StoreResume(db: db, replaceStmt: replaceStmt, peerManager: peerManager)

  resume.initTransferHandler(wakuArchive, wakuStoreClient)

  return ok(resume)

proc getLastOnlineTimestamp*(self: StoreResume): Result[Timestamp, string] =
  var timestamp: Timestamp

  proc queryCallback(s: ptr sqlite3_stmt) =
    timestamp = sqlite3_column_int64(s, 0)

  self.db.query("SELECT MAX(timestamp) FROM last_online", queryCallback).isOkOr:
    return err("failed to query: " & $error)

  return ok(timestamp)

proc setLastOnlineTimestamp*(
    self: StoreResume, timestamp: Timestamp
): Result[void, string] =
  self.replaceStmt.exec((timestamp)).isOkOr:
    return err("failed to execute replace stmt" & $error)

  return ok()

proc startStoreResume*(
    self: StoreResume, time: Timestamp, peer: RemotePeerInfo
): Future[Result[void, string]] {.async.} =
  info "starting store resume", lastOnline = $time, peer = $peer

  # get the callback we saved if possible
  let callback = self.transferCallBack.valueOr:
    return err("transfer callback uninitialised")

  # run the callback
  (await callback(time, peer)).isOkOr:
    return err("transfer callback failed: " & $error)

  info "store resume completed"

  return ok()

proc autoStoreResume*(self: StoreResume): Future[Result[void, string]] {.async.} =
  let peer = self.peerManager.selectPeer(WakuStoreCodec).valueOr:
    return err("no suitable peer found for store resume")

  let lastOnlineTs = self.getLastOnlineTimestamp().valueOr:
    return err("failed to get last online timestamp: " & $error)

  # Limit the resume time range
  let now = getNowInNanosecondTime()
  let maxTime = now - (ResumeRangeLimit * 3600 * 1_000_000_000)
  let ts = max(lastOnlineTs, maxTime)

  return await self.startStoreResume(ts, peer)

proc periodicSetLastOnline(self: StoreResume) {.async.} =
  ## Save a timestamp periodically
  ## so that a node can know when it was last online
  while true:
    await sleepAsync(LastOnlineInterval)

    let ts = getNowInNanosecondTime()

    self.setLastOnlineTimestamp(ts).isOkOr:
      error "failed to set last online timestamp", error, time = ts

proc start*(self: StoreResume) {.async.} =
  # start resume process, will try thrice.
  var tries = 3
  while tries > 0:
    (await self.autoStoreResume()).isOkOr:
      tries -= 1
      error "store resume failed", triesLeft = tries, error = $error
      await sleepAsync(30.seconds)
      continue

    break

  # starting periodic storage of last online timestamp
  self.handle = self.periodicSetLastOnline()

proc stopWait*(self: StoreResume) {.async.} =
  if not self.handle.isNil():
    await noCancel(self.handle.cancelAndWait())

  self.replaceStmt.dispose()
  self.db.close()
