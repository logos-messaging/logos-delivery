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
  mixnodes*: seq[string]
    ## Mix bootstrap nodes as `multiaddr:mixPublicKey`, the `--mixnode` form. The
    ## addresses are `dns4` names, which stay valid when a fleet node moves hosts;
    ## the node resolves them in the background after the mount.
  p2pReliability*: bool
  maxPureLibp2pPeers*: int

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
      "enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im",
      "/dns4/node-01.ac-cn-hongkong-c.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp",
      "/dns4/node-01.do-ams3.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W",
      "/dns4/node-01.gc-us-central1-a.waku.test.status.im/tcp/30303/p2p/16Uiu2HAmDCp8XJ9z1ev18zuv8NHekAsjNyezAvmMfFEJkiharitG",
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
    mixnodes: @[
      "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby:c288a425a6209c74ec07e2e8b6816e9b6995d1cd59b1ab482317c3dfb3ba200f",
      "/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmMK7PYygBtKUQ8EHp7EfaD3bCEsJrkFooK8RQ2PVpJprH:9d92279057940efd2e5e98c8922c079c24e45c083b00360c8dc6a298b1661716",
      "/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397:fe60e95c50f70db9015525064e1fff962ccc982dde480f8faae30262710ece58",
      "/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8Y9kgBNtjxvCnf1X6gnZJW5EGE4UwwCL3CCm55TwqBiH:312335324231ba7963c0c7524e042d1beac2927dbf810513a7fc8d901ab4e812",
      "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8YokiNun9BkeA1ZRmhLbtNUvcwRr64F69tYj9fkGyuEP:7d683767f23f5132a79c70587fec877575460122ebd459bb29c887b7b7a32110",
      "/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAkvwhGHKNry6LACrB8TmEFoCJKEX29XR5dDUzk3UT3UNSE:0894b2852890d244e045f2ff5875e03a6b18f233ccd2e5297f62f7546e93884d",
    ],
    maxPureLibp2pPeers: 50,
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
    mixnodes: @[
      "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj:f4451493c120b6ea29fe81041d86c73cc5cf51f3ab0245b91bac6415ed73f414",
      "/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG:a7213a0c15f148f5845998be7191834fdabf0cd384f93b29fbe9f426215a923c",
      "/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3:77f7b2fff4e3e6f39c9cfe8cc6f944e67235b9501a80b73689ed48fa370f715a",
      "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7:3e90943b68f0e35a0182f9e369f9fb2f3239949d36e5642a0030794d7cb98314",
      "/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF:0573cca393d50bca75a34e4fe5d3f9e703c7ef0f8b94af199ff05e9b21c76201",
      "/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV:9b6f8e546762eaaa863778701f1a6f6dca37e7f03e64c9e35307b05018444a17",
    ],
    maxPureLibp2pPeers: 50,
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
