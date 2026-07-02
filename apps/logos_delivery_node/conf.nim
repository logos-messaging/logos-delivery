{.push raises: [].}

import confutils, confutils/defs
import ../../tools/confutils/cli_args

export cli_args

## App-specific configuration for `logos_delivery_node`.
##
## `WakuNodeConf` is flattened in, so every waku switch (including the `cmd`
## subcommand discriminator) is hoisted into this type's CLI namespace. New
## app-only switches live alongside it and become global options, leaving the
## shared `WakuNodeConf` (and wakunode2) untouched.
type LogosDeliveryNodeConf* = object
  waku* {.flatten.}: WakuNodeConf

  presetsFile* {.
    desc: "Path to a presets file to load node presets from",
    defaultValue: "",
    name: "presets-file"
  .}: string

proc load*(T: type LogosDeliveryNodeConf, version = ""): ConfResult[T] =
  try:
    let conf = LogosDeliveryNodeConf.load(
      version = version,
      secondarySources = proc(
          conf: LogosDeliveryNodeConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile("logosdeliverynode"))

        if conf.waku.configFile.isSome():
          sources.addConfigFile(Toml, conf.waku.configFile.get())
      ,
    )

    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

{.pop.}
