{.push raises: [].}

import std/sequtils, stew/leb128

import ../common/protobuf, ../waku_core/message, ../waku_core/time, ./common

const
  HashLen = 32
  VarIntLen = 9
  AvgCapacity = 1000

proc validateDecoded(value: WakuMessageAndTopic): ProtobufResult[void] =
  if value.pubsub.len == 0:
    return err(ProtobufError.missingRequiredField("pubsub"))
  validateWakuMessageFields(value.message)

protobufCodec(WakuMessageAndTopic, validateDecoded)

proc deltaEncode*(itemSet: ItemSet): seq[byte] =
  # 1 byte for resolved bool and 32 bytes hash plus 9 bytes varint per elements 
  let capacity = 1 + (itemSet.elements.len * (VarIntLen + HashLen))

  var
    output = newSeqOfCap[byte](capacity)
    lastTime = Timestamp(0)
    buf = Leb128Buf[uint64]()

  for id in itemSet.elements:
    let timeDiff = uint64(id.time) - uint64(lastTime)
    lastTime = id.time

    # encode timestamp
    buf = timediff.toBytes(Leb128)
    output &= @buf

    output &= id.hash

  output &= byte(itemSet.reconciled)

  return output

proc encodeUpperBound(
    output: var seq[byte],
    bound: SyncID,
    lastTimestamp: var Timestamp,
    lastHash: var Fingerprint,
) =
  let timeDiff = uint64(bound.time) - uint64(lastTimestamp)
  lastTimestamp = bound.time

  let previousHash = lastHash
  lastHash = bound.hash

  # encode timestamp
  let buf = timeDiff.toBytes(Leb128)
  output &= @buf

  if timeDiff == 0:
    var sameBytes = 0
    for (byte1, byte2) in zip(previousHash, bound.hash):
      sameBytes.inc()

      if byte1 != byte2:
        break

    # encode number of same bytes
    output &= byte(sameBytes)

    # encode hash bytes
    output &= bound.hash[0 ..< sameBytes]

proc deltaEncode*(value: RangesData): seq[byte] =
  var
    output = newSeqOfCap[byte](AvgCapacity)
    buf = Leb128Buf[uint64]()
    lastTimestamp: Timestamp
    lastHash: Fingerprint
    i = 0
    j = 0

  # encode cluster and shards
  buf = uint64(value.cluster).toBytes(Leb128)
  output &= @buf

  buf = uint64(value.shards.len).toBytes(Leb128)
  output &= @buf

  for shard in value.shards:
    buf = uint64(shard).toBytes(Leb128)
    output &= @buf

  # an empty payload is the header alone
  if value.ranges.len == 0:
    return output

  # The first range starts at SyncID 0, so a first range that starts later is
  # preceded by a Skip range up to its lower bound.
  let start = value.ranges[0][0].a
  if start != SyncID(time: Timestamp(0), hash: EmptyWakuMessageHash):
    output.encodeUpperBound(start, lastTimestamp, lastHash)
    output &= byte(RangeType.Skip)

  for (bound, rangeType) in value.ranges:
    output.encodeUpperBound(bound.b, lastTimestamp, lastHash)

    # encode rangeType
    output &= byte(rangeType)

    case rangeType
    of RangeType.Skip:
      continue
    of RangeType.Fingerprint:
      output &= value.fingerprints[i]
      i.inc()
    of RangeType.ItemSet:
      let itemSet = value.itemSets[j]
      j.inc()

      # encode how many elements are in the set
      buf = uint64(itemSet.elements.len).toBytes(Leb128)
      output &= @buf

      let encodedSet = itemSet.deltaEncode()

      output &= encodedSet

    continue

  return output

proc getItemSetLength(idx: var int, buffer: seq[byte]): int =
  let min = min(idx + VarIntLen, buffer.len)
  let slice = buffer[idx ..< min]
  let (val, len) = uint64.fromBytes(slice, Leb128)
  idx += len

  return int(val)

proc getFingerprint(idx: var int, buffer: seq[byte]): Result[Fingerprint, string] =
  if idx + HashLen > buffer.len:
    return err("Cannot decode fingerprint")

  let slice = buffer[idx ..< idx + HashLen]
  idx += HashLen
  var fingerprint = EmptyFingerprint
  for i, bytes in slice:
    fingerprint[i] = bytes

  return ok(fingerprint)

proc getRangeType(idx: var int, buffer: seq[byte]): Result[RangeType, string] =
  if idx >= buffer.len:
    return err("Cannot decode range type")

  let val = buffer[idx]

  if val > 2 or val < 0:
    return err("Cannot decode range type")

  let rangeType = RangeType(val)
  idx += 1

  return ok(rangeType)

proc updateHash(
    idx: var int, buffer: seq[byte], hash: var WakuMessageHash
): Result[void, string] =
  if idx >= buffer.len:
    return err("Cannot decode hash prefix")

  let sameBytes = int(buffer[idx])

  if sameBytes > 32:
    return err("Cannot decode hash prefix")

  idx += 1

  if idx + sameBytes > buffer.len:
    return err("Cannot decode hash prefix")

  let slice = buffer[idx ..< idx + sameBytes]
  idx += sameBytes

  for i, bytes in slice:
    hash[i] = bytes

  return ok()

proc getTimeDiff(idx: var int, buffer: seq[byte]): Timestamp =
  let min = min(idx + VarIntLen, buffer.len)
  let slice = buffer[idx ..< min]
  let (val, len) = uint64.fromBytes(slice, Leb128)
  idx += len

  return Timestamp(val)

proc getTimestamp(idx: var int, buffer: seq[byte]): Result[Timestamp, string] =
  if idx + VarIntLen > buffer.len:
    return err("Cannot decode timestamp")

  let slice = buffer[idx ..< idx + VarIntLen]
  let (val, len) = uint64.fromBytes(slice, Leb128)
  idx += len

  return ok(Timestamp(val))

proc getHash(idx: var int, buffer: seq[byte]): Result[WakuMessageHash, string] =
  if idx + HashLen > buffer.len:
    return err("Cannot decode hash")

  let slice = buffer[idx ..< idx + HashLen]
  idx += HashLen
  var hash = EmptyWakuMessageHash
  for i, bytes in slice:
    hash[i] = bytes

  return ok(hash)

proc getReconciled(idx: var int, buffer: seq[byte]): Result[bool, string] =
  if idx >= buffer.len:
    return err("Cannot decode reconciled")

  let val = buffer[idx]

  if val > 1 or val < 0:
    return err("Cannot decode reconciled")

  let recon = bool(val)
  idx += 1

  return ok(recon)

proc getVarint(idx: var int, buffer: seq[byte]): Opt[uint64] =
  ## A header-only payload ends right after its last varint, so fewer than
  ## VarIntLen bytes left is not an error here.
  if idx >= buffer.len:
    return Opt.none(uint64)

  let slice = buffer[idx ..< min(idx + VarIntLen, buffer.len)]
  let (val, len) = uint64.fromBytes(slice, Leb128)
  if len <= 0:
    return Opt.none(uint64)
  idx += len

  return Opt.some(val)

proc getCluster(idx: var int, buffer: seq[byte]): Result[uint16, string] =
  let cluster = getVarint(idx, buffer).valueOr:
    return err("Cannot decode cluster")
  if cluster > uint64(high(uint16)):
    return err("Cannot decode cluster")

  return ok(uint16(cluster))

proc getShards(idx: var int, buffer: seq[byte]): Result[seq[uint16], string] =
  let count = getVarint(idx, buffer).valueOr:
    return err("Cannot decode shard count")
  # every shard takes at least one byte, and there are at most 65536 distinct shards
  if count > min(uint64(buffer.len - idx), uint64(high(uint16)) + 1):
    return err("Cannot decode shard count")

  var shards = newSeqOfCap[uint16](int(count))
  for i in 0 ..< int(count):
    let shard = getVarint(idx, buffer).valueOr:
      return err("Cannot decode shard. Shard index: " & $i)
    if shard > uint64(high(uint16)):
      return err("Cannot decode shard. Shard index: " & $i)
    shards.add(uint16(shard))

  return ok(shards)

proc deltaDecode*(
    itemSet: var ItemSet, buffer: seq[byte], setLength: int
): Result[int, string] =
  var
    lastTime = Timestamp(0)
    idx = 0

  while itemSet.elements.len < setLength:
    let timeDiff = ?getTimestamp(idx, buffer)
    if timeDiff > Timestamp.high - lastTime:
      return err("Cannot decode timestamp")
    let time = lastTime + timeDiff
    lastTime = time

    let hash = ?getHash(idx, buffer)

    let id = SyncID(time: time, hash: hash)

    itemSet.elements.add(id)

  itemSet.reconciled = ?getReconciled(idx, buffer)

  return ok(idx)

proc getItemSet(
    idx: var int, buffer: seq[byte], itemSetLength: int
): Result[ItemSet, string] =
  var itemSet = ItemSet()
  let slice = buffer[idx ..< buffer.len]
  let count = ?deltaDecode(itemSet, slice, itemSetLength)
  idx += count

  return ok(itemSet)

proc deltaDecode*(T: type RangesData, buffer: seq[byte]): Result[T, string] =
  if buffer.len == 0:
    return ok(RangesData())

  var
    payload = RangesData()
    lastBound = SyncID(time: Timestamp(0), hash: EmptyWakuMessageHash)
    idx = 0

  payload.cluster = ?getCluster(idx, buffer)
  payload.shards = ?getShards(idx, buffer)

  # The first range starts at SyncID 0. An empty payload is the header alone.
  while idx < buffer.len:
    let lowerRangeBound = lastBound

    let timeDiff = getTimeDiff(idx, buffer)
    if timeDiff > Timestamp.high - lastBound.time:
      return err("Cannot decode time difference")

    var hash = EmptyWakuMessageHash
    if timeDiff == 0:
      ?updateHash(idx, buffer, hash)

    let upperRangeBound = SyncID(time: lastBound.time + timeDiff, hash: hash)
    if not (lowerRangeBound < upperRangeBound):
      return err("Range upper bound is not above its lower bound")
    lastBound = upperRangeBound

    let bounds = lowerRangeBound .. upperRangeBound

    let rangeType = ?getRangeType(idx, buffer)
    payload.ranges.add((bounds, rangeType))

    if rangeType == RangeType.Fingerprint:
      let fingerprint = ?getFingerprint(idx, buffer)
      payload.fingerprints.add(fingerprint)
    elif rangeType == RangeType.ItemSet:
      let itemSetLength = getItemSetLength(idx, buffer)
      let itemSet = ?getItemSet(idx, buffer, itemSetLength)
      payload.itemSets.add(itemSet)

  return ok(payload)
