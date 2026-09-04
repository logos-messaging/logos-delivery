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
  ## Structured (preset + overrides) entry: `mode` and `preset` shape the kernel
  ## conf for every layer, `kernel` included - it just yields no upper layers.
  ## `init(kernelConf)` is the raw entry that takes a caller's config as-is.
  let merged = merge(?resolvePreset(preset), messagingOverrides)
  var kernelConf = ?toWakuNodeConf(merged, mode)
  kernelConf.preset = preset
  kernelConf.entryLayer = entryLayer
  return ok(
    LogosDeliveryConf(
      kernelConf: KernelConf(kernelConf),
      messagingConf:
        if entryLayer != EntryLayer.kernel:
          Opt.some(merged)
        else:
          Opt.none(MessagingClientConf),
      channelsConf:
        if entryLayer == EntryLayer.channels:
          Opt.some(channelsOverrides)
        else:
          Opt.none(ReliableChannelManagerConf),
    )
  )

{.pop.}
