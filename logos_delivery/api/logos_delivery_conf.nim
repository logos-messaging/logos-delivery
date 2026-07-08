{.push raises: [].}

import results

import logos_delivery/api/messaging_conf
import logos_delivery/channels/reliable_channel_manager

export messaging_conf, reliable_channel_manager

type LogosDeliveryConf* = object ## Aggregates the per-layer config objects.
  kernelConf*: KernelConf
  messagingConf*: MessagingClientConf
  channelsConf*: ReliableChannelManagerConf

proc init*(
    T: type LogosDeliveryConf,
    mode: WakuMode,
    preset: string,
    messagingOverrides: MessagingClientConf,
    channelsOverrides: ReliableChannelManagerConf,
): ConfResult[LogosDeliveryConf] =
  let merged = merge(?resolvePreset(preset), messagingOverrides)
  var kernelConf = ?toKernelConf(merged, mode)
  kernelConf.preset = preset
  return ok(
    LogosDeliveryConf(
      kernelConf: kernelConf, messagingConf: merged, channelsConf: channelsOverrides
    )
  )

{.pop.}
