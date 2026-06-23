## Core identifier types for the Reliable Channel API.

import std/hashes
import logos_delivery/api/types as api_types

import ./scalable_data_sync/scalable_data_sync

export scalable_data_sync
export api_types

type ChannelId* = SdsChannelID

proc hash*(r: RequestId): Hash =
  ## Allows `RequestId` to be used as a `Table` key.
  hash(string(r))
