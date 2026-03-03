{.push raises: [].}

import chronicles, results, stint

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

type NetworkConf* = object
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

# cluster-id=1 (aka The Waku Network)
# Cluster configuration corresponding to The Waku Network. Note that it
# overrides existing cli configuration
proc TheWakuNetworkConf*(T: type NetworkConf): NetworkConf =
  const RelayChainId = 59141'u256
  return NetworkConf(
    maxMessageSize: "150KiB",
    clusterId: 1,
    rlnRelay: true,
    rlnRelayEthContractAddress: "0xB9cd878C90E49F797B4431fBF4fb333108CB90e6",
    rlnRelayDynamic: true,
    rlnRelayChainId: RelayChainId,
    rlnEpochSizeSec: 600,
    rlnRelayUserMessageLimit: 100,
    shardingConf: ShardingConf(kind: AutoSharding, numShardsInCluster: 8),
    discv5Discovery: true,
    discv5BootstrapNodes: @[
      "enr:-QESuED0qW1BCmF-oH_ARGPr97Nv767bl_43uoy70vrbah3EaCAdK3Q0iRQ6wkSTTpdrg_dU_NC2ydO8leSlRpBX4pxiAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOTd-h5owwj-cx7xrmbvQKU8CV3Fomfdvcv1MBc-67T5oN0Y3CCdl-DdWRwgiMohXdha3UyDw",
      "enr:-QEkuED9X80QF_jcN9gA2ZRhhmwVEeJnsg_Hyg7IFCTYnZD0BDI7a8HArE61NhJZFwygpHCWkgwSt2vqiABXkBxzIqZBAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQPFAS8zz2cg1QQhxMaK8CzkGQ5wdHvPJcrgLzJGOiHpwYN0Y3CCdl-DdWRwgiMohXdha3UyDw",
      "enr:-QEkuEBfEzJm_kigJ2HoSS_RBFJYhKHocGdkhhBr6jSUAWjLdFPp6Pj1l4yiTQp7TGHyu1kC6FyaU573VN8klLsEm-XuAYJpZIJ2NIJpcIQI2SVcim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOwsS69tgD7u1K50r5-qG5hweuTwa0W26aYPnvivpNlrYN0Y3CCdl-DdWRwgiMohXdha3UyDw",
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
