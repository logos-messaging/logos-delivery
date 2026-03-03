{.used.}

import std/options, results, stint, testutils/unittests
import json_serialization
import waku/api/api_conf, waku/factory/waku_conf, waku/factory/networks_config
import waku/common/logging

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
    let entryNodes = @[
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
    let staticStoreNodes = @[
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
        entryNodes = @[
          "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
        ],
        staticStoreNodes = @[
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
    let entryNodes = @[
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

suite "NodeConfig JSON - complete format":
  test "Full NodeConfig from complete JSON with field validation":
    ## Given
    let jsonStr = """
    {
      "mode": "Core",
      "protocolsConfig": {
        "entryNodes": ["enrtree://TREE@nodes.example.com"],
        "staticStoreNodes": ["/ip4/1.2.3.4/tcp/80/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"],
        "clusterId": 10,
        "autoShardingConfig": {
          "numShardsInCluster": 4
        },
        "messageValidation": {
          "maxMessageSize": "100 KiB",
          "rlnConfig": null
        }
      },
      "networkingConfig": {
        "listenIpv4": "192.168.1.1",
        "p2pTcpPort": 7000,
        "discv5UdpPort": 7001
      },
      "ethRpcEndpoints": ["http://localhost:8545"],
      "p2pReliability": true,
      "logLevel": "WARN",
      "logFormat": "TEXT"
    }
    """

    ## When
    let config = decodeNodeConfigFromJson(jsonStr)

    ## Then — check every field
    check:
      config.mode == WakuMode.Core
      config.ethRpcEndpoints == @["http://localhost:8545"]
      config.p2pReliability == true
      config.logLevel == LogLevel.WARN
      config.logFormat == LogFormat.TEXT

    check:
      config.networkingConfig.listenIpv4 == "192.168.1.1"
      config.networkingConfig.p2pTcpPort == 7000
      config.networkingConfig.discv5UdpPort == 7001

    let pc = config.protocolsConfig
    check:
      pc.entryNodes == @["enrtree://TREE@nodes.example.com"]
      pc.staticStoreNodes ==
        @[
          "/ip4/1.2.3.4/tcp/80/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
        ]
      pc.clusterId == 10
      pc.autoShardingConfig.numShardsInCluster == 4
      pc.messageValidation.maxMessageSize == "100 KiB"
      pc.messageValidation.rlnConfig.isNone()

  test "Full NodeConfig with RlnConfig present":
    ## Given
    let jsonStr = """
    {
      "mode": "Edge",
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "messageValidation": {
          "maxMessageSize": "150 KiB",
          "rlnConfig": {
            "contractAddress": "0x1234567890ABCDEF1234567890ABCDEF12345678",
            "chainId": 5,
            "epochSizeSec": 600
          }
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    ## When
    let config = decodeNodeConfigFromJson(jsonStr)

    ## Then
    check config.mode == WakuMode.Edge

    let mv = config.protocolsConfig.messageValidation
    check:
      mv.maxMessageSize == "150 KiB"
      mv.rlnConfig.isSome()
    let rln = mv.rlnConfig.get()
    check:
      rln.contractAddress == "0x1234567890ABCDEF1234567890ABCDEF12345678"
      rln.chainId == 5'u
      rln.epochSizeSec == 600'u64

  test "Round-trip encode/decode preserves all fields":
    ## Given
    let original = NodeConfig.init(
      mode = Edge,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @["enrtree://TREE@example.com"],
        staticStoreNodes = @[
          "/ip4/1.2.3.4/tcp/80/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
        ],
        clusterId = 42,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 16),
        messageValidation = MessageValidation(
          maxMessageSize: "256 KiB",
          rlnConfig: some(
            RlnConfig(
              contractAddress: "0xAABBCCDDEEFF00112233445566778899AABBCCDD",
              chainId: 137,
              epochSizeSec: 300,
            )
          ),
        ),
      ),
      networkingConfig =
        NetworkingConfig(listenIpv4: "10.0.0.1", p2pTcpPort: 9090, discv5UdpPort: 9091),
      ethRpcEndpoints = @["https://rpc.example.com"],
      p2pReliability = true,
      logLevel = LogLevel.DEBUG,
      logFormat = LogFormat.JSON,
    )

    ## When
    let decoded = decodeNodeConfigFromJson(Json.encode(original))

    ## Then — check field by field
    check:
      decoded.mode == original.mode
      decoded.ethRpcEndpoints == original.ethRpcEndpoints
      decoded.p2pReliability == original.p2pReliability
      decoded.logLevel == original.logLevel
      decoded.logFormat == original.logFormat
      decoded.networkingConfig.listenIpv4 == original.networkingConfig.listenIpv4
      decoded.networkingConfig.p2pTcpPort == original.networkingConfig.p2pTcpPort
      decoded.networkingConfig.discv5UdpPort == original.networkingConfig.discv5UdpPort
      decoded.protocolsConfig.entryNodes == original.protocolsConfig.entryNodes
      decoded.protocolsConfig.staticStoreNodes ==
        original.protocolsConfig.staticStoreNodes
      decoded.protocolsConfig.clusterId == original.protocolsConfig.clusterId
      decoded.protocolsConfig.autoShardingConfig.numShardsInCluster ==
        original.protocolsConfig.autoShardingConfig.numShardsInCluster
      decoded.protocolsConfig.messageValidation.maxMessageSize ==
        original.protocolsConfig.messageValidation.maxMessageSize
      decoded.protocolsConfig.messageValidation.rlnConfig.isSome()

    let decodedRln = decoded.protocolsConfig.messageValidation.rlnConfig.get()
    let originalRln = original.protocolsConfig.messageValidation.rlnConfig.get()
    check:
      decodedRln.contractAddress == originalRln.contractAddress
      decodedRln.chainId == originalRln.chainId
      decodedRln.epochSizeSec == originalRln.epochSizeSec

suite "NodeConfig JSON - partial format with defaults":
  test "Minimal NodeConfig - empty object uses all defaults":
    ## Given
    let config = decodeNodeConfigFromJson("{}")
    let defaultConfig = NodeConfig.init()

    ## Then — compare field by field against defaults
    check:
      config.mode == defaultConfig.mode
      config.ethRpcEndpoints == defaultConfig.ethRpcEndpoints
      config.p2pReliability == defaultConfig.p2pReliability
      config.logLevel == defaultConfig.logLevel
      config.logFormat == defaultConfig.logFormat
      config.networkingConfig.listenIpv4 == defaultConfig.networkingConfig.listenIpv4
      config.networkingConfig.p2pTcpPort == defaultConfig.networkingConfig.p2pTcpPort
      config.networkingConfig.discv5UdpPort ==
        defaultConfig.networkingConfig.discv5UdpPort
      config.protocolsConfig.entryNodes == defaultConfig.protocolsConfig.entryNodes
      config.protocolsConfig.staticStoreNodes ==
        defaultConfig.protocolsConfig.staticStoreNodes
      config.protocolsConfig.clusterId == defaultConfig.protocolsConfig.clusterId
      config.protocolsConfig.autoShardingConfig.numShardsInCluster ==
        defaultConfig.protocolsConfig.autoShardingConfig.numShardsInCluster
      config.protocolsConfig.messageValidation.maxMessageSize ==
        defaultConfig.protocolsConfig.messageValidation.maxMessageSize
      config.protocolsConfig.messageValidation.rlnConfig.isSome() ==
        defaultConfig.protocolsConfig.messageValidation.rlnConfig.isSome()

  test "Minimal NodeConfig keeps network preset defaults":
    ## Given
    let config = decodeNodeConfigFromJson("{}")

    ## Then
    check:
      config.protocolsConfig.entryNodes == TheWakuNetworkPreset.entryNodes
      config.protocolsConfig.messageValidation.rlnConfig.isSome()

  test "NodeConfig with only mode specified":
    ## Given
    let config = decodeNodeConfigFromJson("""{"mode": "Edge"}""")

    ## Then
    check:
      config.mode == WakuMode.Edge
      ## Remaining fields get defaults
      config.logLevel == LogLevel.INFO
      config.logFormat == LogFormat.TEXT
      config.p2pReliability == false
      config.ethRpcEndpoints == newSeq[string]()

  test "ProtocolsConfig partial - optional fields get defaults":
    ## Given — only entryNodes and clusterId provided
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": ["enrtree://X@y.com"],
        "clusterId": 5
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    ## When
    let config = decodeNodeConfigFromJson(jsonStr)

    ## Then — required fields are set, optionals get defaults
    check:
      config.protocolsConfig.entryNodes == @["enrtree://X@y.com"]
      config.protocolsConfig.clusterId == 5
      config.protocolsConfig.staticStoreNodes == newSeq[string]()
      config.protocolsConfig.autoShardingConfig.numShardsInCluster ==
        DefaultAutoShardingConfig.numShardsInCluster
      config.protocolsConfig.messageValidation.maxMessageSize ==
        DefaultMessageValidation.maxMessageSize
      config.protocolsConfig.messageValidation.rlnConfig.isNone()

  test "MessageValidation partial - rlnConfig omitted defaults to none":
    ## Given
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "messageValidation": {
          "maxMessageSize": "200 KiB"
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    ## When
    let config = decodeNodeConfigFromJson(jsonStr)

    ## Then
    check:
      config.protocolsConfig.messageValidation.maxMessageSize == "200 KiB"
      config.protocolsConfig.messageValidation.rlnConfig.isNone()

  test "logLevel and logFormat omitted use defaults":
    ## Given
    let jsonStr = """
    {
      "mode": "Core",
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    ## When
    let config = decodeNodeConfigFromJson(jsonStr)

    ## Then
    check:
      config.logLevel == LogLevel.INFO
      config.logFormat == LogFormat.TEXT

suite "NodeConfig JSON - unsupported fields raise errors":
  test "Unknown field at NodeConfig level raises":
    let jsonStr = """
    {
      "mode": "Core",
      "unknownTopLevel": true
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Typo in NodeConfig field name raises":
    let jsonStr = """
    {
      "modes": "Core"
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Unknown field in ProtocolsConfig raises":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "futureField": "something"
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Unknown field in NetworkingConfig raises":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000,
        "futureNetworkField": "value"
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Unknown field in MessageValidation raises":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "messageValidation": {
          "maxMessageSize": "150 KiB",
          "maxMesssageSize": "typo"
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Unknown field in RlnConfig raises":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "messageValidation": {
          "maxMessageSize": "150 KiB",
          "rlnConfig": {
            "contractAddress": "0xABCDEF1234567890ABCDEF1234567890ABCDEF12",
            "chainId": 1,
            "epochSizeSec": 600,
            "unknownRlnField": true
          }
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Unknown field in AutoShardingConfig raises":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "autoShardingConfig": {
          "numShardsInCluster": 8,
          "shardPrefix": "extra"
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

suite "NodeConfig JSON - missing required fields":
  test "Missing 'entryNodes' in ProtocolsConfig":
    let jsonStr = """
    {
      "protocolsConfig": {
        "clusterId": 1
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Missing 'clusterId' in ProtocolsConfig":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": []
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Missing required fields in NetworkingConfig":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0"
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Missing 'numShardsInCluster' in AutoShardingConfig":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "autoShardingConfig": {}
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Missing required fields in RlnConfig":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "messageValidation": {
          "maxMessageSize": "150 KiB",
          "rlnConfig": {
            "contractAddress": "0xABCD"
          }
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Missing 'maxMessageSize' in MessageValidation":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": 1,
        "messageValidation": {
          "rlnConfig": null
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

suite "NodeConfig JSON - invalid values":
  test "Invalid enum value for mode":
    var raised = false
    try:
      discard decodeNodeConfigFromJson("""{"mode": "InvalidMode"}""")
    except SerializationError:
      raised = true
    check raised

  test "Invalid enum value for logLevel":
    var raised = false
    try:
      discard decodeNodeConfigFromJson("""{"logLevel": "SUPERVERBOSE"}""")
    except SerializationError:
      raised = true
    check raised

  test "Wrong type for clusterId (string instead of number)":
    let jsonStr = """
    {
      "protocolsConfig": {
        "entryNodes": [],
        "clusterId": "not-a-number"
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      }
    }
    """

    var raised = false
    try:
      discard decodeNodeConfigFromJson(jsonStr)
    except SerializationError:
      raised = true
    check raised

  test "Completely invalid JSON syntax":
    var raised = false
    try:
      discard decodeNodeConfigFromJson("""{ not valid json at all }""")
    except SerializationError:
      raised = true
    check raised

suite "NodeConfig JSON -> WakuConf integration":
  test "Decoded config translates to valid WakuConf":
    ## Given
    let jsonStr = """
    {
      "mode": "Core",
      "protocolsConfig": {
        "entryNodes": [
          "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
        ],
        "staticStoreNodes": [
          "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
        ],
        "clusterId": 55,
        "autoShardingConfig": {
          "numShardsInCluster": 6
        },
        "messageValidation": {
          "maxMessageSize": "256 KiB",
          "rlnConfig": null
        }
      },
      "networkingConfig": {
        "listenIpv4": "0.0.0.0",
        "p2pTcpPort": 60000,
        "discv5UdpPort": 9000
      },
      "ethRpcEndpoints": ["http://localhost:8545"],
      "p2pReliability": true,
      "logLevel": "INFO",
      "logFormat": "TEXT"
    }
    """

    ## When
    let nodeConfig = decodeNodeConfigFromJson(jsonStr)
    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 55
      wakuConf.shardingConf.numShardsInCluster == 6
      wakuConf.maxMessageSizeBytes == 256'u64 * 1024'u64
      wakuConf.staticNodes.len == 1
      wakuConf.p2pReliability == true
