{.used.}

import std/os, testutils/unittests, results, confutils

import tools/confutils/cli_args

import
  ../../apps/rlnkeystore/rlnkeystore,
  ../../logos_delivery/waku/common/logging,
  ../../logos_delivery/waku/factory/conf_builder/rln_relay_conf_builder

suite "rlnkeystore config - former generateRlnKeystore options":
  test "accepts the node options the subcommand accepted":
    ## When
    let conf = RlnKeystoreConf.load(
      cmdLine = @[
        "--rln-relay-epoch-sec=600", "--max-msg-size=1KiB", "--rln-relay-cred-path=/cli"
      ]
    ).valueOr:
      raiseAssert error

    ## Then
    check:
      conf.rlnRelayCredPath == "/cli"
      conf.rlnEpochSizeSec == Opt.some(600'u64)
      conf.maxMessageSize == "1KiB"

  test "reads a node TOML config file, command line first":
    ## Given
    let path = getTempDir() / "rlnkeystore_conf_test.toml"
    writeFile(
      path,
      "tcp-port = 60001\ncluster-id = 1\n" &
        "rln-relay-cred-path = \"/file\"\nrln-relay-cred-password = \"secret\"\n",
    )
    defer:
      removeFile(path)

    ## When
    let fromFile = RlnKeystoreConf.load(cmdLine = @["--config-file=" & path]).valueOr:
      raiseAssert error
    let overridden = RlnKeystoreConf.load(
      cmdLine = @["--config-file=" & path, "--rln-relay-cred-path=/cli"]
    ).valueOr:
      raiseAssert error

    ## Then
    check:
      fromFile.rlnRelayCredPath == "/file"
      fromFile.rlnRelayCredPassword == "secret"
      overridden.rlnRelayCredPath == "/cli"
      overridden.rlnRelayCredPassword == "secret"

  test "reads LOGOS_DELIVERY_NODE_ variables, RLNKEYSTORE_ first":
    ## Given
    putEnv("LOGOS_DELIVERY_NODE_RLN_RELAY_CRED_PATH", "/node")
    putEnv("LOGOS_DELIVERY_NODE_RLN_RELAY_CRED_PASSWORD", "node-secret")
    defer:
      delEnv("LOGOS_DELIVERY_NODE_RLN_RELAY_CRED_PATH")
      delEnv("LOGOS_DELIVERY_NODE_RLN_RELAY_CRED_PASSWORD")

    ## When
    let fromNode = RlnKeystoreConf.load(cmdLine = @[]).valueOr:
      raiseAssert error

    putEnv("RLNKEYSTORE_RLN_RELAY_CRED_PATH", "/tool")
    defer:
      delEnv("RLNKEYSTORE_RLN_RELAY_CRED_PATH")
    let fromBoth = RlnKeystoreConf.load(cmdLine = @[]).valueOr:
      raiseAssert error

    ## Then
    check:
      fromNode.rlnRelayCredPath == "/node"
      fromNode.rlnRelayCredPassword == "node-secret"
      fromBoth.rlnRelayCredPath == "/tool"
      fromBoth.rlnRelayCredPassword == "node-secret"
