## Reliable Channel layer API — channel send operation.
import std/tables
import results, chronos

import logos_delivery/api/types
import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/reliable_channel

proc send*(
    self: ReliableChannelManager,
    channelId: ChannelId,
    appPayload: seq[byte],
    ephemeral: bool = false,
): Future[Result[RequestId, string]] {.async: (raises: []).} =
  ## Spec-level entry point. Looks the channel up by id and delegates
  ## to `ReliableChannel.send`, which exposes the visible pipeline
  ## segmentation -> sds -> rate_limit_manager -> encryption.
  let chn = self.channels.getOrDefault(channelId)
  if chn.isNil():
    return err("unknown channel: " & channelId)
  return await chn.send(appPayload, ephemeral)
