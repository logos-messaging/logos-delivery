import chronos

import ../../waku_core/time, ../common

proc calculateTimeRange*(
    jitter: Duration = 20.seconds, syncRange: Duration = 1.hours
): Slice[Timestamp] =
  ## Calculates the start and end time of a sync session

  var now = getNowInNanosecondTime()

  # Because of message jitter inherent to Relay protocol
  now -= jitter.nanos

  let syncRange = syncRange.nanos

  let syncStart = now - syncRange
  let syncEnd = now

  return Timestamp(syncStart) .. Timestamp(syncEnd)

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
