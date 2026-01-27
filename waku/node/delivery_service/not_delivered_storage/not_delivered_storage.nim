## This module is aimed to keep track of the sent/published messages that are considered
## not being properly delivered.
##
## The archiving of such messages will happen in a local sqlite database.
##
## In the very first approach, we consider that a message is sent properly is it has been
## received by any store node.
##

import results
import
  ../../../common/databases/db_sqlite,
  ../../../waku_core/message/message,
  ../../../node/delivery_service/not_delivered_storage/migrations

const NotDeliveredMessagesDbUrl = "not-delivered-messages.db"

type NotDeliveredStorage* = ref object
  database: SqliteDatabase

type TrackedWakuMessage = object
  msg: WakuMessage
  numTrials: uint
    ## for statistics purposes. Counts the number of times the node has tried to publish it

proc new*(T: type NotDeliveredStorage): Result[T, string] =
  let db = ?SqliteDatabase.new(NotDeliveredMessagesDbUrl)

  ?migrate(db)

  return ok(NotDeliveredStorage(database: db))

proc archiveMessage*(
    self: NotDeliveredStorage, msg: WakuMessage
): Result[void, string] =
  ## Archives a waku message so that we can keep track of it
  ## even when the app restarts
  return ok()
