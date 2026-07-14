{.push raises: [].}

import results

import logos_delivery/api/conf/modes
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/conf/channels_conf

export modes, messaging_conf, channels_conf

type LogosDeliveryConf* = object
  ## Aggregates the per-layer config objects. A layer is mounted iff its config
  ## is present.
  kernelConf*: KernelConf
  messagingConf*: Opt[MessagingClientConf]
  channelsConf*: Opt[ReliableChannelManagerConf]

proc init*(T: type LogosDeliveryConf, kernelConf: KernelConf): LogosDeliveryConf =
  return LogosDeliveryConf(kernelConf: kernelConf)

proc init*(
    T: type LogosDeliveryConf,
    entryLayer: EntryLayer = EntryLayer.channels,
    mode: LogosDeliveryMode,
    preset: string,
    messagingOverrides: MessagingClientConf,
    channelsOverrides: ReliableChannelManagerConf,
): ConfResult[LogosDeliveryConf] =
  ## Structured (preset + overrides) entry. Only `messaging` / `channels` layers
  ## reach here; the `kernel` layer uses `init(kernelConf)` (raw, mode ignored).
  let merged = merge(?resolvePreset(preset), messagingOverrides)
  var kernelConf = ?toWakuNodeConf(merged, mode)
  kernelConf.preset = preset
  return ok(
    LogosDeliveryConf(
      kernelConf: KernelConf(kernelConf),
      messagingConf: Opt.some(merged),
      channelsConf:
        if entryLayer == EntryLayer.channels:
          Opt.some(channelsOverrides)
        else:
          Opt.none(ReliableChannelManagerConf),
    )
  )

{.pop.}
