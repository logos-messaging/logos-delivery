{.push raises: [].}

import std/options
import results
import ./cli_args
import ./optionalize

const WakuNodeConfOverlayExcludes* = ["cmd", "execute"]
  ## Variant-safety: `cmd` is the CLI subcommand discriminator (not dispatched
  ## on by the library) and `execute` lives in its inactive branch. Excluded
  ## from the overlay AND used as the JSON parser's hard-reject list.

# Generates the WakuNodeConfOverlay type from the WakuNodeConf type.
# The generated type converts fields from type T to Option[T] if T != Option.
# Skips fields that are in WakuNodeConfOverlayExcludes.
optionalizeType(WakuNodeConfOverlay, WakuNodeConf, WakuNodeConfOverlayExcludes)

proc init*(T: type WakuNodeConfOverlay): WakuNodeConfOverlay =
  ## Default config overlay where every field is `none`.
  return WakuNodeConfOverlay()

proc applyAsOverride*(conf: var WakuNodeConf, overlay: WakuNodeConfOverlay) =
  ## For all fields, overlay.some() overrides field of same name in conf.
  for confName, confValue in fieldPairs(conf):
    for ovName, ovValue in fieldPairs(overlay):
      when confName == ovName:
        if ovValue.isSome():
          when typeof(confValue) is Option:
            confValue = ovValue
          else:
            confValue = ovValue.get()

proc applyAsAddition*(conf: var WakuNodeConf, overlay: WakuNodeConfOverlay) =
  ## For all seq fields, overlay.some() concats to field of same name in conf.
  for confName, confValue in fieldPairs(conf):
    for ovName, ovValue in fieldPairs(overlay):
      when confName == ovName:
        when typeof(confValue) is seq:
          if ovValue.isSome() and ovValue.get().len > 0:
            confValue = confValue & ovValue.get()
