{.push raises: [].}

import std/options
import results

import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/conf/channels_conf

export options, messaging_conf, channels_conf

type LogosDeliveryConf* = object
  ## Aggregates the per-layer config objects. A layer is mounted iff its config
  ## is present.
  kernelConf*: KernelConf
  messagingConf*: Option[MessagingClientConf]
  channelsConf*: Option[ReliableChannelManagerConf]

proc init*(T: type LogosDeliveryConf, kernelConf: KernelConf): LogosDeliveryConf =
  return LogosDeliveryConf(kernelConf: kernelConf)

proc init*(
    T: type LogosDeliveryConf,
    mode: LogosDeliveryMode,
    preset: string,
    messagingOverrides: MessagingClientConf,
    channelsOverrides: ReliableChannelManagerConf,
): ConfResult[LogosDeliveryConf] =
  let merged = merge(?resolvePreset(preset), messagingOverrides)
  var kernelConf = ?toWakuNodeConf(merged, mode)
  kernelConf.preset = preset
  return ok(
    LogosDeliveryConf(
      kernelConf: KernelConf(kernelConf),
      messagingConf: some(merged),
      channelsConf: some(channelsOverrides),
    )
  )

{.pop.}
