## Core identifier types for the Reliable Channel API.
##
## Kept separate from `events.nim` so identifier definitions don't
## travel with event payload definitions.

import std/hashes
import bearssl/rand
import waku/utils/requests as request_utils

import ./scalable_data_sync/scalable_data_sync

export scalable_data_sync

type
  ChannelId* = SdsChannelID

  ReliableRequestId* = distinct string
    ## Channel-level (parent) request id returned by `ReliableChannel.send`.
    ## A single `ReliableRequestId` fans out into one-or-more delivery-service
    ## `RequestId`s — one per dispatched segment.

proc new*(T: typedesc[ReliableRequestId], rng: ref HmacDrbgContext): T =
  ReliableRequestId(request_utils.generateRequestId(rng))

proc `$`*(r: ReliableRequestId): string {.inline.} =
  string(r)

proc `==`*(a, b: ReliableRequestId): bool {.inline.} =
  string(a) == string(b)

proc hash*(r: ReliableRequestId): Hash =
  ## Allows `ReliableRequestId` to be used as a `Table` key.
  hash(string(r))
