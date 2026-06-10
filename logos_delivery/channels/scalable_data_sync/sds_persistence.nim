## Persistence backend for SDS outgoing buffer and causal history.
##
## TODO (raised in PR review): this surface is duplicating concerns that
## should come from the SDS module itself. Once the SDS module exposes a
## complete persistence contract, drop this file and import that surface
## instead of re-declaring it here.

import message

type
  SdsPersistenceKind* {.pure.} = enum
    InMemory
    Sqlite

  SdsPersistence* = ref object of RootObj
    kind*: SdsPersistenceKind

method storeOutgoing*(self: SdsPersistence, msg: SdsMessage) {.base.} =
  discard

method markAcknowledged*(self: SdsPersistence, messageId: SdsMessageID) {.base.} =
  discard

method unackedOlderThan*(self: SdsPersistence, ageMs: int): seq[SdsMessage] {.base.} =
  discard
