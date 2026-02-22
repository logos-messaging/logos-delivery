{.used.}

import chronos, testutils/unittests, std/options

import waku

suite "Waku API - Create node":
  asyncTest "Create node with minimal configuration":
    ## Given
    let nodeConfig = NodeConfig.init(
      protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 1)
    )

    # This is the actual minimal config but as the node auto-start, it is not suitable for tests
    # NodeConfig.init(ethRpcEndpoints = @["http://someaddress"])

    ## When
    let node = (await createNode(nodeConfig)).valueOr:
      raiseAssert error

    ## Then
    check:
      not node.isNil()
      node.conf.clusterId == 1
      node.conf.relay == true

  asyncTest "Create node with full configuration":
    ## Given
    let nodeConfig = NodeConfig.init(
      mode = Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[
          "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
        ],
        staticStoreNodes = @[
          "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
        ],
        clusterId = 99,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 16),
        messageValidation =
          MessageValidation(maxMessageSize: "1024 KiB", rlnConfig: none(RlnConfig)),
      ),
    )

    ## When
    let node = (await createNode(nodeConfig)).valueOr:
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
    let nodeConfig = NodeConfig.init(
      mode = Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[
          "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
          "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
        ],
        clusterId = 42,
      ),
    )

    ## When
    let node = (await createNode(nodeConfig)).valueOr:
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
