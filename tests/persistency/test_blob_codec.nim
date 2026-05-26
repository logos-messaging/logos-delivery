{.used.}

## Round-trip tests for the generic payload blob codec (payload_codec.nim)
## and its `BlobCodec` application to the SDS persistence types.
##
## Importing `sds_persistency` forces the real adapter (and its six
## `BlobCodec` calls + call sites) to compile. The local derivations
## below live in this module's own scope and drive the round-trip checks.

import std/[sets, times]
import testutils/unittests
import waku/persistency/payload_codec
import waku/persistency/sds_persistency # compile-checks the real adapter
import sds/types/persistence

# Same order constraint as the adapter: a field's type before its container.
BlobCodec(HistoryEntry)
BlobCodec(SdsMessage)
BlobCodec(UnacknowledgedMessage)
BlobCodec(IncomingMessage)
BlobCodec(OutgoingRepairEntry)
BlobCodec(IncomingRepairEntry)

proc sampleHistory(): HistoryEntry =
  HistoryEntry.init("mid-1", @[0xAA'u8, 0xBB, 0xCC], "sender-1".SdsParticipantID)

proc sampleMessage(content = @[1'u8, 2, 3]): SdsMessage =
  SdsMessage.init(
    messageId = "msg-42",
    lamportTimestamp = 7'i64,
    causalHistory = @[sampleHistory(), HistoryEntry.init("mid-2")],
    channelId = "channel-9",
    content = content,
    bloomFilter = @[0xDE'u8, 0xAD, 0xBE, 0xEF],
    senderId = "alice".SdsParticipantID,
    repairRequest = @[sampleHistory()],
  )

suite "Persistency blob codec":
  test "primitive round-trips":
    check fromBlob(toBlob(7'i64), int64) == 7'i64
    check fromBlob(toBlob(int64.low), int64) == int64.low
    check fromBlob(toBlob("héllo"), string) == "héllo"
    check fromBlob(toBlob(@[0'u8, 255, 7]), seq[byte]) == @[0'u8, 255, 7]

  test "HistoryEntry round-trips":
    let h = sampleHistory()
    check fromBlob(toBlob(h), HistoryEntry) == h

  test "SdsMessage round-trips (seqs, distinct, nested)":
    let m = sampleMessage()
    check fromBlob(toBlob(m), SdsMessage) == m

  test "UnacknowledgedMessage round-trips (Time, int)":
    let u = UnacknowledgedMessage.init(sampleMessage(), initTime(1_700_000_000, 123), 4)
    check fromBlob(toBlob(u), UnacknowledgedMessage) == u

  test "IncomingMessage round-trips (HashSet)":
    let inc = IncomingMessage.init(sampleMessage(), toHashSet(["dep-a", "dep-b", "dep-c"]))
    check fromBlob(toBlob(inc), IncomingMessage) == inc

  test "repair tuples round-trip":
    let outPair =
      ("msg-42".SdsMessageID, OutgoingRepairEntry.init(sampleHistory(), initTime(10, 0)))
    check fromBlob(toBlob(outPair), (SdsMessageID, OutgoingRepairEntry)) == outPair

    let inPair = (
      "msg-42".SdsMessageID,
      IncomingRepairEntry.init(sampleHistory(), @[9'u8, 8, 7], initTime(20, 500)),
    )
    check fromBlob(toBlob(inPair), (SdsMessageID, IncomingRepairEntry)) == inPair

  test "payload exceeds the old 64 KiB key cap (4-byte length)":
    var big = newSeq[byte](70_000)
    for i in 0 ..< big.len:
      big[i] = byte(i and 0xFF)
    let m = sampleMessage(content = big)
    let decoded = fromBlob(toBlob(m), SdsMessage)
    check decoded.content.len == 70_000
    check decoded == m

  test "truncated input raises ValueError":
    let bytes = toBlob(sampleMessage())
    expect ValueError:
      discard fromBlob(bytes[0 ..< bytes.len - 5], SdsMessage)
    expect ValueError:
      discard fromBlob(@[0xFF'u8, 0xFF, 0xFF, 0xFF], string) # claims 4 GiB
