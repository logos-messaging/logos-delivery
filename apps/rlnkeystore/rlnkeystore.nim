{.push raises: [].}

import std/[os, sequtils], chronicles, confutils, results, stew/endians2, stint
import
  ../../tools/[rln_keystore_generator/rln_keystore_generator, confutils/cli_args],
  logos_delivery/waku/common/logging,
  logos_delivery/waku/factory/conf_builder/rln_relay_conf_builder

logScope:
  topics = "rlnkeystore main"

const git_version* {.strdefine.} = "n/a"

type RlnKeystoreConf* = object
  configFile* {.
    desc: "Loads configuration from a TOML file (cmd-line parameters take precedence)",
    name: "config-file"
  .}: Opt[InputFile]

  logLevel* {.
    desc:
      "Sets the log level for process. Supported levels: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL",
    defaultValue: logging.LogLevel.INFO,
    name: "log-level"
  .}: logging.LogLevel

  logFormat* {.
    desc:
      "Specifies what kind of logs should be written to stdout. Supported formats: TEXT, JSON",
    defaultValue: logging.LogFormat.TEXT,
    name: "log-format"
  .}: logging.LogFormat

  rlnRelayCredPath* {.
    desc: "The path for persisting rln-relay credential",
    defaultValue: "",
    name: "rln-relay-cred-path"
  .}: string

  ethClientUrls* {.
    desc:
      "HTTP address of an Ethereum testnet client e.g., http://localhost:8540/. Argument may be repeated.",
    defaultValue: @[EthRpcUrl("http://localhost:8540/")],
    defaultValueDesc: "http://localhost:8540/",
    name: "rln-relay-eth-client-address"
  .}: seq[EthRpcUrl]

  rlnRelayEthContractAddress* {.
    desc: "Address of membership contract on an Ethereum testnet.",
    defaultValue: "",
    name: "rln-relay-eth-contract-address"
  .}: string

  rlnRelayChainId* {.
    desc:
      "Chain ID of the provided contract (optional, will fetch from RPC provider if not used)",
    defaultValue: 0,
    name: "rln-relay-chain-id"
  .}: uint

  rlnRelayCredPassword* {.
    desc: "Password for encrypting RLN credentials",
    defaultValue: "",
    name: "rln-relay-cred-password"
  .}: string

  rlnRelayEthPrivateKey* {.
    desc: "Private key for broadcasting transactions",
    defaultValue: "",
    name: "rln-relay-eth-private-key"
  .}: string

  rlnRelayUserMessageLimit* {.
    desc:
      "Set a user message limit for the rln membership registration. Must be a positive integer. Default is " &
      $DefaultRlnRelayUserMessageLimit & ".",
    defaultValue: Opt.none(uint64),
    name: "rln-relay-user-message-limit"
  .}: Opt[uint64]

  # Accepted but unused, as in the former `generateRlnKeystore` subcommand, so
  # its invocations keep working.
  rlnEpochSizeSec* {.
    desc: "Not used by keystore generation; accepted for compatibility with the node.",
    defaultValue: Opt.none(uint64),
    name: "rln-relay-epoch-sec"
  .}: Opt[uint64]

  maxMessageSize* {.
    desc: "Not used by keystore generation; accepted for compatibility with the node.",
    defaultValue: DefaultMaxWakuMessageSizeStr,
    name: "max-msg-size"
  .}: string

  execute* {.
    desc: "Runs the registration function on-chain. By default, a dry-run will occur",
    defaultValue: false,
    name: "execute"
  .}: bool

func toGeneratorConf(conf: RlnKeystoreConf): RlnKeystoreGeneratorConf =
  RlnKeystoreGeneratorConf(
    execute: conf.execute,
    chainId: UInt256.fromBytesBE(conf.rlnRelayChainId.toBytesBE()),
    ethClientUrls: conf.ethClientUrls.mapIt(string(it)),
    ethContractAddress: conf.rlnRelayEthContractAddress,
    userMessageLimit: conf.rlnRelayUserMessageLimit.get(DefaultRlnRelayUserMessageLimit),
    ethPrivateKey: conf.rlnRelayEthPrivateKey,
    credPath: conf.rlnRelayCredPath,
    credPassword: conf.rlnRelayCredPassword,
  )

proc load*(
    T: type RlnKeystoreConf, version = "", cmdLine = commandLineParams()
): ConfResult[T] =
  try:
    let conf = RlnKeystoreConf.load(
      version = version,
      cmdLine = cmdLine,
      secondarySources = proc(
          conf: RlnKeystoreConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile("rlnkeystore"))
        # The former subcommand read the node's variables and config file;
        # keep both working. Unknown TOML keys are the node's own options.
        sources.addConfigFile(Envvar, InputFile(NodeEnvvarPrefix))

        if conf.configFile.isSome():
          sources.addConfigFileWithParams(
            Toml, conf.configFile.get(), flags = {TomlUnknownFields}
          )
      ,
    )
    return ok(conf)
  except CatchableError:
    return err(getCurrentExceptionMsg())

{.pop.}

when isMainModule:
  let conf = RlnKeystoreConf.load(version = "version / git commit hash: " & git_version).valueOr:
    error "failure while loading the configuration", error = error
    quit(QuitFailure)

  logging.setupLog(conf.logLevel, conf.logFormat)
  doRlnKeystoreGenerator(conf.toGeneratorConf())
