{.push raises: [].}

import std/[options, strutils], stew/[endians2, byteutils]
import ../common/paging
import ./common

const StoreEligibilityDomainPrefixHead* = "/LEZ/v0.1/StoreEligibility/"

static:
  doAssert StoreEligibilityDomainPrefixHead.len == 27

proc storeEligibilityDomainPrefixBytes*(): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< StoreEligibilityDomainPrefixHead.len:
    result[i] = byte(StoreEligibilityDomainPrefixHead[i])

proc appendLeU32(buf: var seq[byte], value: uint32) =
  buf.add toBytes(value, Endianness.littleEndian)

proc appendLeU64(buf: var seq[byte], value: uint64) =
  buf.add toBytes(value, Endianness.littleEndian)

proc appendLeI64(buf: var seq[byte], value: int64) =
  appendLeU64(buf, cast[uint64](value))

proc appendBorshString*(buf: var seq[byte], value: string) =
  appendLeU32(buf, uint32(value.len))
  for ch in value:
    buf.add byte(uint8(ch))

proc appendOptionalString*(buf: var seq[byte], value: Option[string]) =
  if value.isSome():
    buf.add byte(1)
    buf.appendBorshString(value.get())
  else:
    buf.add byte(0)

proc appendOptionalInt64*(buf: var seq[byte], value: Option[int64]) =
  if value.isSome():
    buf.add byte(1)
    appendLeI64(buf, value.get())
  else:
    buf.add byte(0)

proc appendOptionalUint64*(buf: var seq[byte], value: Option[uint64]) =
  if value.isSome():
    buf.add byte(1)
    appendLeU64(buf, value.get())
  else:
    buf.add byte(0)

proc storeEligibilityCanonicalBody*(req: StoreQueryRequest): seq[byte] =
  var buf = newSeqOfCap[byte](256)
  buf.appendBorshString(req.requestId)
  buf.add byte(if req.includeData: 1 else: 0)
  let pubsub =
    if req.pubsubTopic.isSome(): some($req.pubsubTopic.get()) else: none(string)
  buf.appendOptionalString(pubsub)
  appendLeU32(buf, uint32(req.contentTopics.len))
  for topic in req.contentTopics:
    buf.appendBorshString($topic)
  buf.appendOptionalInt64(
    if req.startTime.isSome(): some(int64(req.startTime.get())) else: none(int64)
  )
  buf.appendOptionalInt64(
    if req.endTime.isSome(): some(int64(req.endTime.get())) else: none(int64)
  )
  appendLeU32(buf, uint32(req.messageHashes.len))
  for h in req.messageHashes:
    buf.add h.toOpenArray(0, h.high)
  if req.paginationCursor.isSome():
    buf.add byte(1)
    buf.add req.paginationCursor.get().toOpenArray(0, 31)
  else:
    buf.add byte(0)
  buf.add byte(if req.paginationForward.into(): 1 else: 0)
  buf.appendOptionalUint64(req.paginationLimit)
  buf

proc storeEligibilityCanonicalPayload*(req: StoreQueryRequest): seq[byte] =
  var req = req
  req.eligibilityProof = none(seq[byte])
  result = newSeqOfCap[byte](32 + 256)
  result.add storeEligibilityDomainPrefixBytes()
  result.add storeEligibilityCanonicalBody(req)

proc bytesToLowerHex*(data: openArray[byte]): string =
  const hexChars = "0123456789abcdef"
  result = newString(data.len * 2)
  var j = 0
  for b in data:
    result[j] = hexChars[int(b shr 4) and 0xF]
    result[j + 1] = hexChars[int(b) and 0xF]
    j += 2

proc storeEligibilityCanonicalHex*(req: StoreQueryRequest): string =
  bytesToLowerHex(storeEligibilityCanonicalPayload(req))
