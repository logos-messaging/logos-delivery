{.used.}

import std/[net, options]

import chronos, testutils/unittests

import waku
import tools/confutils/cli_args
import waku/factory/networks_config
import waku/factory/conf_builder/conf_builder

suite "Waku API - Create node":
  asyncTest "Create node with minimal configuration":
    ## Given
    var nodeConf = defaultWakuNodeConf().valueOr:
      raiseAssert "defaultWakuNodeConf failed: " & error
    nodeConf.mode = Core
    nodeConf.clusterId = some(3'u16)
    nodeConf.rest = false

    # This is the actual minimal config but as the node auto-start, it is not suitable for tests

    ## When
    let node = (await createNode(nodeConf)).valueOr:
      raiseAssert "createNode (minimal config) failed: " & error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 3
      node.conf.relay == true

  asyncTest "Create node with full configuration":
    ## Given
    var nodeConf = defaultWakuNodeConf().valueOr:
      raiseAssert "defaultWakuNodeConf failed: " & error
    nodeConf.mode = Core
    nodeConf.clusterId = some(99'u16)
    nodeConf.rest = false
    nodeConf.numShardsInNetwork = 16
    nodeConf.maxMessageSize = "1024 KiB"
    nodeConf.entryNodes = @[
      "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
    ]
    nodeConf.staticnodes = @[
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
    ]

    ## When
    let node = (await createNode(nodeConf)).valueOr:
      raiseAssert "createNode (full config) failed: " & error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 99
      node.conf.shardingConf.numShardsInCluster == 16
      node.conf.maxMessageSizeBytes == 1024'u64 * 1024'u64
      node.conf.staticNodes.len == 1
      node.conf.relay == true
      node.conf.lightPush == true
      node.conf.peerExchangeService == true
      node.conf.rendezvous == true

  asyncTest "Create node with mixed entry nodes (enrtree, multiaddr)":
    ## Given
    var nodeConf = defaultWakuNodeConf().valueOr:
      raiseAssert "defaultWakuNodeConf failed: " & error
    nodeConf.mode = Core
    nodeConf.clusterId = some(42'u16)
    nodeConf.rest = false
    nodeConf.entryNodes = @[
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
    ]

    ## When
    let node = (await createNode(nodeConf)).valueOr:
      raiseAssert "createNode (mixed entry nodes) failed: " & error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 42
      # ENRTree should go to DNS discovery
      node.conf.dnsDiscoveryConf.isSome()
      node.conf.dnsDiscoveryConf.get().enrTreeUrl ==
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      # Multiaddr should go to static nodes
      node.conf.staticNodes.len == 1
      node.conf.staticNodes[0] ==
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

  asyncTest "Create node via messaging API with overrides":
    let
      clusterId = 3'u16
      numShards = 1'u16
    let overrides = WakuNodeConfOverlay(
      clusterId: some(clusterId), rest: some(false), numShardsInNetwork: some(numShards)
    )

    let node = (await createNode(mode = cli_args.WakuMode.Core, overrides = overrides)).valueOr:
      raiseAssert "createNode (overrides only) failed: " & error

    check:
      not node.isNil()
      node.conf.clusterId == clusterId
      node.conf.shardingConf.numShardsInCluster == numShards

  asyncTest "Create node via messaging API with overrides + additions":
    let
      clusterId = 7'u16
      staticnode =
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
    let overrides = WakuNodeConfOverlay(
      clusterId: some(clusterId), rest: some(false), numShardsInNetwork: some(1'u16)
    )
    let additions = WakuNodeConfOverlay(staticnodes: some(@[staticnode]))

    let node = (
      await createNode(
        mode = cli_args.WakuMode.Core, overrides = overrides, additions = additions
      )
    ).valueOr:
      raiseAssert "createNode (overrides + additions) failed: " & error

    check:
      not node.isNil()
      node.conf.clusterId == clusterId
      node.conf.staticNodes.len == 1
      node.conf.staticNodes[0] == staticnode

  asyncTest "Create node via messaging API with preset":
    let
      preset = "twn"
      twn = NetworkConf.TheWakuNetworkConf()
    let overrides = WakuNodeConfOverlay(rest: some(false))

    let node = (
      await createNode(
        preset = preset, mode = cli_args.WakuMode.Edge, overrides = overrides
      )
    ).valueOr:
      raiseAssert "createNode (preset = " & preset & ") failed: " & error

    check:
      not node.isNil()
      node.conf.clusterId == twn.clusterId
      node.conf.shardingConf.kind == twn.shardingConf.kind
      node.conf.shardingConf.numShardsInCluster == twn.shardingConf.numShardsInCluster
      node.conf.discv5Conf.isSome()
      node.conf.discv5Conf.get().bootstrapNodes.len == twn.discv5BootstrapNodes.len

  asyncTest "Create node via messaging API: additions concat with preset's bootstrap nodes":
    let
      preset = "twn"
      twn = NetworkConf.TheWakuNetworkConf()
      addedBootstrapNode =
        "enr:-QESuED0qW1BCmF-oH_ARGPr97Nv767bl_43uoy70vrbah3EaCAdK3Q0iRQ6wkSTTpdrg_dU_NC2ydO8leSlRpBX4pxiAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOTd-h5owwj-cx7xrmbvQKU8CV3Fomfdvcv1MBc-67T5oN0Y3CCdl-DdWRwgiMohXdha3UyDw"
    let overrides = WakuNodeConfOverlay(rest: some(false))
    let additions =
      WakuNodeConfOverlay(discv5BootstrapNodes: some(@[addedBootstrapNode]))

    let node = (
      await createNode(
        preset = preset,
        mode = cli_args.WakuMode.Edge,
        overrides = overrides,
        additions = additions,
      )
    ).valueOr:
      raiseAssert "createNode (preset = " & preset & " + additions) failed: " & error

    check:
      not node.isNil()
      node.conf.discv5Conf.isSome()
      node.conf.discv5Conf.get().bootstrapNodes.len == twn.discv5BootstrapNodes.len + 1
      node.conf.discv5Conf.get().bootstrapNodes.contains(addedBootstrapNode)

  asyncTest "Messaging API seeds 3 user-ports to 0; metrics/REST keep concrete defaults":
    let overrides = WakuNodeConfOverlay(
      discv5Discovery: some(true),
      websocketSupport: some(true),
      rest: some(true),
      restRelayCacheCapacity: some(50'u32),
      metricsServer: some(true),
    )
    let node = (await createNode(mode = cli_args.WakuMode.Core, overrides = overrides)).valueOr:
      raiseAssert "createNode (port-seeding check) failed: " & error

    check:
      node.conf.endpointConf.p2pTcpPort == Port(0)
      node.conf.discv5Conf.get().udpPort == Port(0)
      node.conf.webSocketConf.get().port == Port(0)
      node.conf.restServerConf.get().port == DefaultRestPort
      node.conf.metricsServerConf.get().httpPort == DefaultMetricsHttpPort

  asyncTest "Messaging API: explicit user overrides win over developer-profile seeding":
    # Caller's explicit tcpPort must take precedence over seedDeveloperProfile's 0.
    let overrides = WakuNodeConfOverlay(tcpPort: some(Port(12345)))
    let node = (await createNode(mode = cli_args.WakuMode.Core, overrides = overrides)).valueOr:
      raiseAssert "createNode (override-wins check) failed: " & error
    check node.conf.endpointConf.p2pTcpPort == Port(12345)

  asyncTest "Messaging API with no overrides: p2pTcpPort seeded to 0":
    let node = (await createNode(mode = cli_args.WakuMode.Core)).valueOr:
      raiseAssert "createNode (no overrides) failed: " & error
    check node.conf.endpointConf.p2pTcpPort == Port(0)
