{.used.}

import chronos, testutils/unittests, std/options

import waku
import tools/confutils/cli_args

suite "Waku API - Create node":
  asyncTest "Create node with minimal configuration":
    ## Given
    var nodeConf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    nodeConf.mode = Core
    nodeConf.clusterId = 3'u16
    nodeConf.rest = false

    # This is the actual minimal config but as the node auto-start, it is not suitable for tests

    ## When
    let node = (await createNode(nodeConf)).valueOr:
      raiseAssert error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 3
      node.conf.relay == true

  asyncTest "Create node with full configuration":
    ## Given
    var nodeConf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    nodeConf.mode = Core
    nodeConf.clusterId = 99'u16
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
      raiseAssert error

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
      raiseAssert error
    nodeConf.mode = Core
    nodeConf.clusterId = 42'u16
    nodeConf.rest = false
    nodeConf.entryNodes = @[
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
    ]

    ## When
    let node = (await createNode(nodeConf)).valueOr:
      raiseAssert error

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
