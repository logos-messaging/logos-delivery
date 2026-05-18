## Persistence backend for SDS outgoing buffer and causal history.

import sds/message

type
  SdsPersistenceKind* {.pure.} = enum
    InMemory
    Sqlite

  SdsPersistence* = ref object of RootObj
    kind*: SdsPersistenceKind

method storeOutgoing*(
    p: SdsPersistence, msg: SdsMessage
) {.base.} =
  discard

method markAcknowledged*(
    p: SdsPersistence, messageId: SdsMessageID
) {.base.} =
  discard

method unackedOlderThan*(
    p: SdsPersistence, ageMs: int
): seq[SdsMessage] {.base.} =
  discard
