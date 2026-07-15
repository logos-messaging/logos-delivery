## Waku Message module.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-message.md
## for spec.

{.push raises: [].}

import ../topics, ../time

const MaxMetaAttrLength* = 64 # 64 bytes

type WakuMessage* = ref object
  # Data payload transmitted.
  ## `WakuMessage` is a `ref object` for performance: every assignment,
  ## async-closure capture, and Result/Option bind-out costs a pointer +
  ## refcount instead of deep-copying the three seqs + the string.
  ##
  ## By convention a `WakuMessage` is **immutable after construction**. Only
  ## mutate an instance you just constructed yourself, or one you obtained via
  ## `clone()`. Mutating a message received through an API or held elsewhere is
  ## a shared-state bug under ref semantics.
  ##
  ## NOTE: this deliberately deviates from the AGENTS.md `Ref`-suffix naming
  ## rule; renaming the ~2,100 occurrences of `WakuMessage` has no semantic
  ## value and would be pure churn.
  payload*: seq[byte]
  # String identifier that can be used for content-based filtering.
  contentTopic*: ContentTopic
  # Application specific metadata.
  meta*: seq[byte]
  # Number to discriminate different types of payload encryption.
  # Compatibility with Whisper/WakuV1.
  version*: uint32
  # Sender generated timestamp.
  timestamp*: Timestamp
  # The ephemeral attribute indicates signifies the transient nature of the
  # message (if the message should be stored).
  ephemeral*: bool
  # Part of RFC 17: https://rfc.vac.dev/spec/17/
  # The proof attribute indicates that the message is not spam. This
  # attribute will be used in the rln-relay protocol.
  proof*: seq[byte]

proc `==`*(a, b: WakuMessage): bool =
  ## Structural equality. Two messages are equal when both are nil, or both are
  ## non-nil with field-wise-equal contents (ref identity is *not* used).
  if a.isNil() or b.isNil():
    return a.isNil() and b.isNil()
  a.payload == b.payload and a.contentTopic == b.contentTopic and a.meta == b.meta and
    a.version == b.version and a.timestamp == b.timestamp and a.ephemeral == b.ephemeral and
    a.proof == b.proof

proc clone*(msg: WakuMessage): WakuMessage =
  ## Explicit deep copy into a fresh ref (copies the payload/meta/proof seqs).
  ## Cloning is the deliberate, rare escape hatch when a held message must be
  ## mutated without affecting other holders.
  if msg.isNil():
    return nil
  WakuMessage(
    payload: msg.payload,
    contentTopic: msg.contentTopic,
    meta: msg.meta,
    version: msg.version,
    timestamp: msg.timestamp,
    ephemeral: msg.ephemeral,
    proof: msg.proof,
  )

proc ensureTimestampSet*(message: WakuMessage): WakuMessage =
  ## Returns `message` unchanged when its timestamp is already set; otherwise
  ## returns a fresh clone with the current timestamp. Never mutates the input
  ## (which may be shared under ref semantics).
  if message.timestamp != 0:
    return message
  result = message.clone()
  result.timestamp = getNowInNanosecondTime()
