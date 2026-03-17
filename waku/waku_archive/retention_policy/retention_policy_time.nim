{.push raises: [].}

import std/times, results, chronicles, chronos
import ../../waku_core, ../driver, ../retention_policy

logScope:
  topics = "waku archive retention_policy"

type TimeRetentionPolicy* = ref object of RetentionPolicy
  retentionTime: chronos.Duration

proc new*(T: type TimeRetentionPolicy, retentionTime: int64): T =
  TimeRetentionPolicy(retentionTime: retentionTime.seconds)

method execute*(
    p: TimeRetentionPolicy, driver: ArchiveDriver
): Future[RetentionPolicyResult[void]] {.async.} =
  ## Delete messages that exceed the retention time
  info "beginning of executing message retention policy - time"

  let now = getNanosecondTime(getTime().toUnixFloat())
  let retentionTimestamp = now - p.retentionTime.nanoseconds

  (await driver.deleteMessagesOlderThanTimestamp(ts = retentionTimestamp)).isOkOr:
    return err("failed to delete oldest messages: " & error)

  info "end of executing message retention policy - time"
  return ok()
