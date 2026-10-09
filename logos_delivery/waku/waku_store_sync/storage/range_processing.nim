import chronos, results

import ../../waku_core/time, ../common

func calculateTimeRange*(
    now: Timestamp, jitter: Duration, syncRange: Duration
): Slice[Timestamp] =
  ## Calculates the start and end time of a sync session relative to `now`

  # Because of message jitter inherent to Relay protocol
  let syncEnd = now - jitter.nanos
  let syncStart = syncEnd - syncRange.nanos

  return syncStart .. syncEnd

func clampSyncRange*(
    syncRange, relayJitter: Duration, timeRetention: Opt[Duration]
): Duration =
  ## Reduces `syncRange` so that `syncRange + relayJitter` never exceeds the
  ## archive's time retention. Without this, the sync window would reach past
  ## what retention keeps, and peers would re-send messages the node deletes.
  if timeRetention.isNone():
    return syncRange

  let retention = timeRetention.get()
  if syncRange + relayJitter <= retention:
    return syncRange

  if retention <= relayJitter:
    return ZeroDuration

  return retention - relayJitter

proc equalPartitioning*(slice: Slice[SyncID], count: int): seq[Slice[SyncID]] =
  ## Partition into N time slices.
  ## Remainder is distributed equaly to the first slices.

  let totalLength: int64 = slice.b.time - slice.a.time

  if totalLength < count:
    return @[]

  let parts = totalLength div count
  var rem = totalLength mod count

  var bounds = newSeqOfCap[Slice[SyncID]](count)

  var lb = slice.a.time

  for i in 0 ..< count:
    var ub = lb + parts

    if rem > 0:
      ub += 1
      rem -= 1

    let lower = SyncID(time: lb, hash: EmptyFingerprint)
    let upper = SyncID(time: ub, hash: EmptyFingerprint)
    let bound = lower .. upper

    bounds.add(bound)

    lb = ub

  return bounds

#TODO implement exponential partitioning
