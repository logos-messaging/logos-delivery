## Core identifier types for the Reliable Channel API.

import std/hashes
import results, chronos
import logos_delivery/api/types as api_types

import ./scalable_data_sync/scalable_data_sync

export scalable_data_sync
export api_types

type ChannelId* = SdsChannelID

type ChannelCryptoFn* = proc(payload: seq[byte]): Future[Result[seq[byte], string]] {.
  async: (raises: []), closure
.}
  ## One direction of an application-supplied channel cipher. Lives here, not
  ## next to the registry, so `ReliableChannelApi` can name it without
  ## importing an implementation module.

proc hash*(r: RequestId): Hash =
  ## Allows `RequestId` to be used as a `Table` key.
  hash(string(r))
