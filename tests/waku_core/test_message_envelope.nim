{.used.}

import std/sequtils, stew/byteutils, testutils/unittests
import logos_delivery/waku/waku_core, ../testlib/wakucore

suite "Waku Message - Envelope":
  test "envelope init computes the same hash as computeMessageHash":
    ## Given
    let pubsubTopic = DefaultPubsubTopic
    let message = fakeWakuMessage(
      contentTopic = DefaultContentTopic,
      payload = "\x01\x02\x03\x04TEST\x05\x06\x07\x08".toBytes(),
      meta = newSeq[byte](),
      ts = getNanosecondTime(1681964442),
    )

    ## When
    let envelope = WakuEnvelope.init(pubsubTopic, message)

    ## Then
    check:
      envelope.hash == computeMessageHash(pubsubTopic, message)
      envelope.pubsubTopic == pubsubTopic
      envelope.msg == message

  test "envelope references the same message (no copy)":
    let pubsubTopic = DefaultPubsubTopic
    let message = fakeWakuMessage(payload = "abc".toBytes())
    let envelope = WakuEnvelope.init(pubsubTopic, message)

    ## The envelope holds the very same ref, not a clone.
    check:
      envelope.msg == message
      # ref identity: mutating through one is visible through the other
      cast[pointer](envelope.msg) == cast[pointer](message)

  test "different topics yield different hashes for the same message":
    let message = fakeWakuMessage(payload = "same-payload".toBytes())
    let e1 = WakuEnvelope.init("/waku/2/rs/0/0", message)
    let e2 = WakuEnvelope.init("/waku/2/rs/0/1", message)

    check:
      e1.hash != e2.hash
      e1.msg == e2.msg
