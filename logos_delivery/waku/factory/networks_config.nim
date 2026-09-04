{.push raises: [].}

import chronicles, results, stint
import logos_delivery/waku/waku_core/message/default_values

logScope:
  topics = "waku networks conf"

type
  ShardingConfKind* = enum
    AutoSharding
    StaticSharding

  ShardingConf* = object
    case kind*: ShardingConfKind
    of AutoSharding:
      numShardsInCluster*: uint16
    of StaticSharding:
      discard

type NetworkPresetConf* = object
  ## A network "preset" (--preset=twn, --preset=logos.dev).
  maxMessageSize*: string # TODO: static convert to a uint64
  clusterId*: uint16
  rlnRelay*: bool
  rlnRelayEthContractAddress*: string
  rlnRelayChainId*: UInt256
  rlnRelayDynamic*: bool
  rlnEpochSizeSec*: uint64
  rlnRelayUserMessageLimit*: uint64
  shardingConf*: ShardingConf
  discv5Discovery*: bool
  discv5BootstrapNodes*: seq[string]
  enableKadDiscovery*: bool
  kadBootstrapNodes*: seq[string]
  entryNodes*: seq[string]
  mix*: bool
  p2pReliability*: bool

# cluster-id=1 (aka The Waku Network)
# Cluster configuration corresponding to The Waku Network. Note that it
# overrides existing cli configuration
proc TheWakuNetworkConf*(T: type NetworkPresetConf): NetworkPresetConf =
  const RelayChainId = 59141'u256
  return NetworkPresetConf(
    maxMessageSize: DefaultMaxWakuMessageSizeStr,
    clusterId: 1,
    rlnRelay: true,
    rlnRelayEthContractAddress: "0xB9cd878C90E49F797B4431fBF4fb333108CB90e6",
    rlnRelayDynamic: true,
    rlnRelayChainId: RelayChainId,
    rlnEpochSizeSec: 600,
    rlnRelayUserMessageLimit: 100,
    shardingConf: ShardingConf(kind: AutoSharding, numShardsInCluster: 8),
    enableKadDiscovery: false,
    kadBootstrapNodes: @[],
    mix: false,
    p2pReliability: false,
    discv5Discovery: true,
    discv5BootstrapNodes: @[],
    entryNodes: @[
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
      "/dns4/node-01.ac-cn-hongkong-c.waku.sandbox.status.im/tcp/30303/p2p/16Uiu2HAmQYiojgZ8APsh9wqbWNyCstVhnp9gbeNrxSEQnLJchC92",
      "/dns4/node-01.do-ams3.waku.sandbox.status.im/tcp/30303/p2p/16Uiu2HAmNaeL4p3WEYzC9mgXBmBWSgWjPHRvatZTXnp8Jgv3iKsb",
      "/dns4/node-01.gc-us-central1-a.waku.sandbox.status.im/tcp/30303/p2p/16Uiu2HAmRv1iQ3NoMMcjbtRmKxPuYBbF9nLYz2SDv9MTN8WhGuUU",
    ],
  )

# cluster-id=3 (Logos Dev Network)
# Cluster configuration for the Logos Dev Network.
proc LogosDevConf*(T: type NetworkPresetConf): NetworkPresetConf =
  const ZeroChainId = 0'u256
  return NetworkPresetConf(
    maxMessageSize: DefaultMaxWakuMessageSizeStr,
    clusterId: 3,
    rlnRelay: false,
    rlnRelayEthContractAddress: "",
    rlnRelayDynamic: false,
    rlnRelayChainId: ZeroChainId,
    rlnEpochSizeSec: 0,
    rlnRelayUserMessageLimit: 0,
    shardingConf: ShardingConf(kind: AutoSharding, numShardsInCluster: 8),
    enableKadDiscovery: true,
    mix: true,
    p2pReliability: true,
    discv5Discovery: true,
    discv5BootstrapNodes: @[],
    entryNodes: @[
      "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby",
      "/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmMK7PYygBtKUQ8EHp7EfaD3bCEsJrkFooK8RQ2PVpJprH",
      "/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397",
      "/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8Y9kgBNtjxvCnf1X6gnZJW5EGE4UwwCL3CCm55TwqBiH",
      "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8YokiNun9BkeA1ZRmhLbtNUvcwRr64F69tYj9fkGyuEP",
      "/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAkvwhGHKNry6LACrB8TmEFoCJKEX29XR5dDUzk3UT3UNSE",
    ],
  )

# cluster-id=2 (Logos Test Network)
# Cluster configuration for the Logos Test Network.
proc LogosTestConf*(T: type NetworkPresetConf): NetworkPresetConf =
  const ZeroChainId = 0'u256
  return NetworkPresetConf(
    maxMessageSize: "150KiB",
    clusterId: 2,
    rlnRelay: false,
    rlnRelayEthContractAddress: "",
    rlnRelayDynamic: false,
    rlnRelayChainId: ZeroChainId,
    rlnEpochSizeSec: 0,
    rlnRelayUserMessageLimit: 0,
    shardingConf: ShardingConf(kind: AutoSharding, numShardsInCluster: 8),
    enableKadDiscovery: true,
    mix: true,
    p2pReliability: true,
    discv5Discovery: true,
    discv5BootstrapNodes: @[],
    entryNodes: @[
      "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj",
      "/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG",
      "/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3",
      "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7",
      "/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF",
      "/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV",
    ],
  )

# cluster-id=16 (Status Production Network)
# Cluster configuration for the `status.prod` network that Status runs on.
# RLN is disabled. Starting from the logos-delivery integration, status.prod
# defaults to auto-sharding with a single shard (numShardsInCluster = 1).
# Bootstrap is done through the status.prod DNS discovery enrtree plus the
# fleet boot nodes.
# Source: https://fleets.waku.org/ and each host's `/config.toml`.
proc StatusProdConf*(T: type NetworkPresetConf): NetworkPresetConf =
  const ZeroChainId = 0'u256
  return NetworkPresetConf(
    maxMessageSize: "1024KiB",
    clusterId: 16,
    rlnRelay: false,
    rlnRelayEthContractAddress: "",
    rlnRelayDynamic: false,
    rlnRelayChainId: ZeroChainId,
    rlnEpochSizeSec: 0,
    rlnRelayUserMessageLimit: 0,
    shardingConf: ShardingConf(kind: AutoSharding, numShardsInCluster: 1),
    enableKadDiscovery: false,
    kadBootstrapNodes: @[],
    mix: false,
    p2pReliability: false,
    discv5Discovery: true,
    discv5BootstrapNodes: @[],
    entryNodes: @[
      "enrtree://AMOJVZX4V6EXP7NTJPMAYJYST2QP6AJXYW76IU6VGJS7UVSNDYZG4@boot.prod.status.nodes.status.im",
      "/dns4/boot-01.do-ams3.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmAR24Mbb6VuzoyUiGx42UenDkshENVDj4qnmmbabLvo31",
      "/dns4/boot-01.gc-us-central1-a.status.prod.status.im/tcp/30303/p2p/16Uiu2HAm8mUZ18tBWPXDQsaF7PbCKYA35z7WB2xNZH2EVq1qS8LJ",
      "/dns4/boot-01.ac-cn-hongkong-c.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmGwcE8v7gmJNEWFtZtojYpPMTHy2jBLL6xRk33qgDxFWX",
    ],
  )

proc validateShards*(
    shardingConf: ShardingConf, shards: seq[uint16]
): Result[void, string] =
  case shardingConf.kind
  of StaticSharding:
    return ok()
  of AutoSharding:
    let numShardsInCluster = shardingConf.numShardsInCluster
    for shard in shards:
      if shard >= numShardsInCluster:
        let msg =
          "validateShards invalid shard: " & $shard & " when numShardsInCluster: " &
          $numShardsInCluster
        error "validateShards failed", error = msg
        return err(msg)

  return ok()
