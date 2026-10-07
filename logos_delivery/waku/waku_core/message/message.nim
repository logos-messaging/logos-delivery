## Waku Message module.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-message.md
## for spec.

{.push raises: [].}

import ../../common/protobuf, ../topics, ../time

const MaxMetaAttrLength* = 64 # 64 bytes

# The fields are in field number order, because the library writes them in
# declaration order. The gossipsub message id is a hash of the encoded bytes,
# so the field order must be the same as in other implementations.
type WakuMessage* {.proto3.} = object # Data payload transmitted.
  payload* {.fieldNumber: 1.}: seq[byte]
  # String identifier that can be used for content-based filtering.
  contentTopic* {.fieldNumber: 2.}: ContentTopic
  # Number to discriminate different types of payload encryption.
  # Compatibility with Whisper/WakuV1.
  version* {.fieldNumber: 3, pint.}: uint32
  # Sender generated timestamp.
  timestamp* {.fieldNumber: 10, sint.}: Timestamp
  # Application specific metadata.
  meta* {.fieldNumber: 11.}: seq[byte]
  # Part of RFC 17: https://rfc.vac.dev/spec/17/
  # The proof attribute indicates that the message is not spam. This
  # attribute will be used in the rln-relay protocol.
  proof* {.fieldNumber: 21.}: seq[byte]
  # The ephemeral attribute marks a message that a store node does not keep.
  ephemeral* {.fieldNumber: 31.}: bool

proc ensureTimestampSet*(message: WakuMessage): WakuMessage =
  result = message
  if result.timestamp == 0:
    result.timestamp = getNowInNanosecondTime()
