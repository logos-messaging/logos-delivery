{.push raises: [].}

import std/net
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
    kernelConf: KernelConf,
    messagingConf: MessagingClientConf,
    channelsConf: Opt[ReliableChannelManagerConf],
): ConfResult[LogosDeliveryConf] =
  ## A node with the Messaging API. An anonymity level above `None` mounts mix,
  ## because the send path can use only a mix that the node mounts.
  var kernel = WakuNodeConf(kernelConf)
  let anonymityLevel = messagingConf.anonymityLevel.get(AnonymityLevel.None)
  if anonymityLevel != AnonymityLevel.None:
    if kernel.mix == Opt.some(false):
      return
        err("anonymityLevel=" & $anonymityLevel & " needs mix, but mix=false was set")
    kernel.mix = Opt.some(true)
  return ok(
    LogosDeliveryConf(
      kernelConf: KernelConf(kernel),
      messagingConf: Opt.some(messagingConf),
      channelsConf: channelsConf,
    )
  )

proc libraryKernelConf*(): ConfResult[WakuNodeConf] =
  ## The kernel defaults of a library node: protocol flags unset, so that a mode
  ## can set them, ports auto-allocated, QUIC on and websocket off.
  var conf = ?defaultKernelConf(modeFlags = ModeProtocolFlags())
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.websocketPort = Port(0)
  conf.websocketSupport = false
  conf.quicSupport = true
  return ok(conf)

proc init*(
    T: type LogosDeliveryConf,
    entryLayer: EntryLayer = EntryLayer.channels,
    mode: LogosDeliveryMode,
    preset: string,
    messagingOverrides: MessagingClientConf,
    channelsOverrides: ReliableChannelManagerConf,
    kernelConf: Opt[KernelConf] = Opt.none(KernelConf),
): ConfResult[LogosDeliveryConf] =
  ## Structured (preset + overrides) entry: `mode` and `preset` shape the kernel
  ## conf for every layer, `kernel` included - it just yields no upper layers.
  ## A field already set in `kernelConf` (default: `libraryKernelConf()`) keeps
  ## its value. `init(kernelConf)` is the raw entry that takes a config as-is.
  var kernel =
    if kernelConf.isSome():
      WakuNodeConf(kernelConf.get())
    else:
      ?libraryKernelConf()
  applyMode(kernel, mode)
  if preset.len > 0:
    kernel.preset = preset
  # The plugin-hosted kademlia and the in-process one are two hosts of one
  # protocol, and the node refuses to run both. Choosing the plugin turns the
  # in-process one off, explicitly, so that a preset enabling it cannot put it
  # back: `checkSetPresetValueToField` leaves an already-set field alone.
  if kernel.pluginKadDiscovery == Opt.some(true):
    kernel.enableKadDiscovery = Opt.some(false)
  # An RLN contract means RLN validation, unless rlnRelay was set explicitly.
  if kernel.rlnRelayEthContractAddress.len > 0 and kernel.rlnRelay.isNone():
    kernel.rlnRelay = Opt.some(true)
  applyModeFlags(kernel, DefaultKernelModeFlags)

  if entryLayer == EntryLayer.kernel:
    return ok(LogosDeliveryConf.init(KernelConf(kernel)))
  return LogosDeliveryConf.init(
    KernelConf(kernel),
    merge(?resolvePreset(preset), messagingOverrides),
    if entryLayer == EntryLayer.channels:
      Opt.some(channelsOverrides)
    else:
      Opt.none(ReliableChannelManagerConf),
  )

{.pop.}
