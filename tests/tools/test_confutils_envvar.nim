{.used.}

import
  std/[os, options],
  results,
  testutils/unittests,
  confutils,
  confutils/defs,
  confutils/std/net
import ../../tools/confutils/[envvar as confEnvvarDefs, envvar_net as confEnvvarNet]

type ConfResult[T] = Result[T, string]

type TestConf = object
  configFile* {.desc: "Configuration file path", name: "config-file".}:
    Option[InputFile]

  testFile* {.desc: "Configuration test file path", name: "test-file".}:
    Option[InputFile]

  listenAddress* {.
    defaultValue: IpAddress(family: IpAddressFamily.IPv4, address_v4: [127u8, 0, 0, 1]),
    desc: "Listening address",
    name: "listen-address"
  .}: IpAddress

  tcpPort* {.desc: "TCP listening port", defaultValue: 60000, name: "tcp-port".}: Port

{.push warning[ProveInit]: off.}

proc load*(T: type TestConf, prefix: string): ConfResult[T] =
  try:
    let conf = TestConf.load(
      secondarySources = proc(
          conf: TestConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile(prefix))
    )
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

{.pop.}

suite "nim-confutils - envvar":
  test "load configuration from environment variables":
    ## Given
    let prefix = "test-prefix"

    let
      listenAddress = "1.1.1.1"
      tcpPort = "8080"
      configFile = "/tmp/test.conf"

    ## When
    os.putEnv("TEST_PREFIX_CONFIG_FILE", configFile)
    os.putEnv("TEST_PREFIX_LISTEN_ADDRESS", listenAddress)
    os.putEnv("TEST_PREFIX_TCP_PORT", tcpPort)

    let confLoadRes = TestConf.load(prefix)

    ## Then
    check confLoadRes.isOk()

    let parsedIpAddress =
      try:
        parseIpAddress(listenAddress)
      except ValueError:
        IpAddress(family: IpAddressFamily.IPv4, address_v4: [0u8, 0, 0, 0])

    let conf = confLoadRes.get()
    check:
      conf.listenAddress == parsedIpAddress
      conf.tcpPort == Port(8080)

      conf.configFile.isSome()
      conf.configFile.get().string == configFile

      conf.testFile.isNone()
