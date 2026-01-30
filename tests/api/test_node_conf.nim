{.used.}

import std/options, results, stint, testutils/unittests
import waku/api/api_conf, waku/factory/waku_conf, waku/factory/networks_config

suite "LibWaku Conf - toWakuConf":
  test "Minimal configuration":
    ## Given
    let nodeConfig = NodeConfig.init(ethRpcEndpoints = @["http://someaddress"])

    ## When
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    let wakuConf = wakuConfRes.valueOr:
      raiseAssert error
    wakuConf.validate().isOkOr:
      raiseAssert error
    check:
      wakuConf.clusterId == 1
      wakuConf.shardingConf.numShardsInCluster == 8
      wakuConf.staticNodes.len == 0

  test "Edge mode configuration":
    ## Given
    let protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 1)

    let nodeConfig = NodeConfig.init(mode = Edge, protocolsConfig = protocolsConfig)

    ## When
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == false
      wakuConf.lightPush == false
      wakuConf.filterServiceConf.isSome() == false
      wakuConf.storeServiceConf.isSome() == false
      wakuConf.peerExchangeService == true
      wakuConf.clusterId == 1

  test "Core mode configuration":
    ## Given
    let protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 1)

    let nodeConfig = NodeConfig.init(mode = Core, protocolsConfig = protocolsConfig)

    ## When
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == true
      wakuConf.lightPush == true
      wakuConf.peerExchangeService == true
      wakuConf.clusterId == 1

  test "Auto-sharding configuration":
    ## Given
    let nodeConfig = NodeConfig.init(
      mode = Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[],
        staticStoreNodes = @[],
        clusterId = 42,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 16),
      ),
    )

    ## When
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 42
      wakuConf.shardingConf.numShardsInCluster == 16

  test "Bootstrap nodes configuration":
    ## Given
    let entryNodes =
      @[
        "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g",
        "enr:-QEkuECnZ3IbVAgkOzv-QLnKC4dRKAPRY80m1-R7G8jZ7yfT3ipEfBrhKN7ARcQgQ-vg-h40AQzyvAkPYlHPaFKk6u9MBgmlkgnY0iXNlY3AyNTZrMaEDk49D8JjMSns4p1XVNBvJquOUzT4PENSJknkROspfAFGg3RjcIJ2X4N1ZHCCd2g",
      ]
    let libConf = NodeConfig.init(
      mode = Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = entryNodes, staticStoreNodes = @[], clusterId = 1
      ),
    )

    ## When
    let wakuConfRes = toWakuConf(libConf)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    require wakuConf.discv5Conf.isSome()
    check:
      wakuConf.discv5Conf.get().bootstrapNodes == entryNodes

  test "Static store nodes configuration":
    ## Given
    let staticStoreNodes =
      @[
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
        "/ip4/192.168.1.1/tcp/60001/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYd",
      ]
    let nodeConf = NodeConfig.init(
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[], staticStoreNodes = staticStoreNodes, clusterId = 1
      )
    )

    ## When
    let wakuConfRes = toWakuConf(nodeConf)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.staticNodes == staticStoreNodes

  test "Message validation with max message size":
    ## Given
    let nodeConfig = NodeConfig.init(
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[],
        staticStoreNodes = @[],
        clusterId = 1,
        messageValidation =
          MessageValidation(maxMessageSize: "100KiB", rlnConfig: none(RlnConfig)),
      )
    )

    ## When
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.maxMessageSizeBytes == 100'u64 * 1024'u64

  test "Message validation with RLN config":
    ## Given
    let nodeConfig = NodeConfig.init(
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[],
        clusterId = 1,
        messageValidation = MessageValidation(
          maxMessageSize: "150 KiB",
          rlnConfig: some(
            RlnConfig(
              contractAddress: "0x1234567890123456789012345678901234567890",
              chainId: 1'u,
              epochSizeSec: 600'u64,
            )
          ),
        ),
      ),
      ethRpcEndpoints = @["http://127.0.0.1:1111"],
    )

    ## When
    let wakuConf = toWakuConf(nodeConfig).valueOr:
      raiseAssert error

    wakuConf.validate().isOkOr:
      raiseAssert error

    check:
      wakuConf.maxMessageSizeBytes == 150'u64 * 1024'u64

    require wakuConf.rlnRelayConf.isSome()
    let rlnConf = wakuConf.rlnRelayConf.get()
    check:
      rlnConf.dynamic == true
      rlnConf.ethContractAddress == "0x1234567890123456789012345678901234567890"
      rlnConf.chainId == 1'u256
      rlnConf.epochSizeSec == 600'u64

  test "Full Core mode configuration with all fields":
    ## Given
    let nodeConfig = NodeConfig.init(
      mode = Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes =
          @[
            "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
          ],
        staticStoreNodes =
          @[
            "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
          ],
        clusterId = 99,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 12),
        messageValidation = MessageValidation(
          maxMessageSize: "512KiB",
          rlnConfig: some(
            RlnConfig(
              contractAddress: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
              chainId: 5'u, # Goerli
              epochSizeSec: 300'u64,
            )
          ),
        ),
      ),
      ethRpcEndpoints = @["https://127.0.0.1:8333"],
    )

    ## When
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    let wakuConf = wakuConfRes.valueOr:
      raiseAssert error
    wakuConf.validate().isOkOr:
      raiseAssert error

    # Check basic settings
    check:
      wakuConf.relay == true
      wakuConf.lightPush == true
      wakuConf.peerExchangeService == true
      wakuConf.rendezvous == true
      wakuConf.clusterId == 99

    # Check sharding
    check:
      wakuConf.shardingConf.numShardsInCluster == 12

    # Check bootstrap nodes
    require wakuConf.discv5Conf.isSome()
    check:
      wakuConf.discv5Conf.get().bootstrapNodes.len == 1

    # Check static nodes
    check:
      wakuConf.staticNodes.len == 1
      wakuConf.staticNodes[0] ==
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    # Check message validation
    check:
      wakuConf.maxMessageSizeBytes == 512'u64 * 1024'u64

    # Check RLN config
    require wakuConf.rlnRelayConf.isSome()
    let rlnConf = wakuConf.rlnRelayConf.get()
    check:
      rlnConf.dynamic == true
      rlnConf.ethContractAddress == "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      rlnConf.chainId == 5'u256
      rlnConf.epochSizeSec == 300'u64

  test "NodeConfig with mixed entry nodes (integration test)":
    ## Given
    let entryNodes =
      @[
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
      ]

    let nodeConfig = NodeConfig.init(
      mode = Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = entryNodes, staticStoreNodes = @[], clusterId = 1
      ),
    )

    ## When
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()

    # Check that ENRTree went to DNS discovery
    require wakuConf.dnsDiscoveryConf.isSome()
    check:
      wakuConf.dnsDiscoveryConf.get().enrTreeUrl == entryNodes[0]

    # Check that multiaddr went to static nodes
    check:
      wakuConf.staticNodes.len == 1
      wakuConf.staticNodes[0] == entryNodes[1]
