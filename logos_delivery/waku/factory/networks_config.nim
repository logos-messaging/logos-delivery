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
      shards*: seq[uint16]
        ## Shard ids a content topic can hash to, `[0..n-1]` by default.
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
  rlnDisableValidation*: bool
    ## Received messages pass unchecked, while published ones still carry
    ## proofs. A node that sets `rln-disable-validation` decides for itself.
  shardingConf*: ShardingConf
  discv5Discovery*: bool
  discv5BootstrapNodes*: seq[string]
  rendezvous*: Opt[bool]
    ## Unset leaves the builder's rule: on for a relay node without service
    ## discovery.
  enableKadDiscovery*: bool
  kadBootstrapNodes*: seq[string]
  entryNodes*: seq[string]
  mix*: bool
  mixnodes*: seq[string]
    ## Mix bootstrap nodes as `multiaddr:mixPublicKey`, the `--mixnode` form. The
    ## addresses are `dns4` names, which stay valid when a fleet node moves hosts;
    ## the node resolves them in the background after the mount.
  mixKeyRotation*: bool
    ## Rotate the mix key. Every node of the network must do the same, so a node
    ## then takes mix keys from discovery only and ignores `mixnodes`.
  p2pReliability*: bool
  extraListenShards*: seq[uint16]
    ## Shards every subscribed content topic is also received on. Deprecated:
    ## removed once Status's shard migration ends,
    ## https://github.com/status-im/status-go/issues/7498.
  storeNodes*: seq[string] ## Multiaddrs of the network's store nodes.

proc autoSharding*(T: type ShardingConf, shards: seq[uint16]): T =
  ShardingConf(kind: AutoSharding, shards: shards)

proc autoSharding*(T: type ShardingConf, numShards: uint16): T =
  ## Auto-sharding over the shards `[0..numShards-1]`.
  var shards = newSeqOfCap[uint16](numShards)
  for i in 0'u16 ..< numShards:
    shards.add(i)
  ShardingConf.autoSharding(shards)

proc autoSharding*(T: type ShardingConf, numShards: uint16, shards: seq[uint16]): T =
  ## Auto-sharding over `numShards` shards with the given ids.
  doAssert shards.len == numShards.int, "shards must hold numShards ids"
  ShardingConf.autoSharding(shards)

proc numShards*(shardingConf: ShardingConf): uint16 =
  uint16(shardingConf.shards.len)

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
    shardingConf: ShardingConf.autoSharding(numShards = 8),
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
    storeNodes: @[
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
    # Relay RLN runs on the plugin a host installs (the delivery module's), so
    # there is no contract address: a relaying node without a plugin turns it
    # off with rln-relay=false. Received proofs are not checked yet.
    rlnRelay: true,
    rlnRelayEthContractAddress: "",
    rlnRelayDynamic: false,
    rlnRelayChainId: ZeroChainId,
    rlnEpochSizeSec: 600,
    rlnRelayUserMessageLimit: 600,
    rlnDisableValidation: true,
    shardingConf: ShardingConf.autoSharding(numShards = 8),
    enableKadDiscovery: true,
    mix: true,
    mixKeyRotation: true,
    mixnodes: @[
      "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmQabBHENv6kgCHAT8Cic517WQqE6RRtrmKVRCDVfazVNj:ec59ba737011531153965bbb6aae37a987bb9e5e5dfc968304b14b6358fd0734",
      "/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmHCgyhHbfhoSdWcsU1ka7Dpx9ZEXfi2qDqSGL2RwnNv4t:a0f2e2182582c3a75fb8a84febadab165bdb43a6aa962d9daf98aa0c51436345",
      "/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397:fe60e95c50f70db9015525064e1fff962ccc982dde480f8faae30262710ece58",
      "/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm9FDUrL2iGDsEFYntjLAFrZEoENgEYjHvPvM14acFCZ3Z:6123db2ba92bc9ad4a079fb1f49690835d5a2cd7e9e5e365a7539f4495fb693a",
      "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmGrh92YTu2UpCHeY8tWAfUhwCkzt48zcX2jjrimQrbEbq:47cc9b29b7172975bd3fc7424a6a2c10284c1371e1322448080347703d0c392d",
      "/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4e3iRT5XumvXDGy2Xa2XybTJsLtqkTiEQacjs2zq661K:921fc5de1082a1df2175710ecabc6c09c282b8f5dc55282d457678ed112e5c60",
    ],
    kadBootstrapNodes: @[
      "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30304/p2p/12D3KooWNupnPMYo87HZjpXoAmRyNP3UbHwk9dAnx82k72j78sdB",
      "/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30304/p2p/12D3KooWFsWheSsxBYapbZLXArUEj34Tpne75EobWgtjD2PvobJZ",
      "/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30304/p2p/16Uiu2HAmBPzDQQ43Nwr8cTtGF4aCACZq4HoGrHpDj9bQDT7fB5mm",
      "/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30304/p2p/12D3KooWA1cq7TLrVMb42SZs8jkNYCFYsHcuYQU75yybDVRuR84U",
      "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30304/p2p/12D3KooWBxY7nJVg34g2me6fvbNzGsMyfLnf6AKrLW54gHPGq1aB",
      "/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30304/p2p/12D3KooWLVvT8GNd9gFatabomXsNoMSPv4ZjV637gQWMWA7YkQ6B",
    ],
    p2pReliability: true,
    discv5Discovery: false,
    discv5BootstrapNodes: @[],
    # Service discovery carries mix keys; Rendezvous would be a second source.
    rendezvous: Opt.some(false),
    entryNodes: @[
      "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmQabBHENv6kgCHAT8Cic517WQqE6RRtrmKVRCDVfazVNj",
      "/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmHCgyhHbfhoSdWcsU1ka7Dpx9ZEXfi2qDqSGL2RwnNv4t",
      "/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397",
      "/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm9FDUrL2iGDsEFYntjLAFrZEoENgEYjHvPvM14acFCZ3Z",
      "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmGrh92YTu2UpCHeY8tWAfUhwCkzt48zcX2jjrimQrbEbq",
      "/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4e3iRT5XumvXDGy2Xa2XybTJsLtqkTiEQacjs2zq661K",
    ],
    storeNodes: @[
      "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmQabBHENv6kgCHAT8Cic517WQqE6RRtrmKVRCDVfazVNj",
      "/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmHCgyhHbfhoSdWcsU1ka7Dpx9ZEXfi2qDqSGL2RwnNv4t",
      "/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397",
      "/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm9FDUrL2iGDsEFYntjLAFrZEoENgEYjHvPvM14acFCZ3Z",
      "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmGrh92YTu2UpCHeY8tWAfUhwCkzt48zcX2jjrimQrbEbq",
      "/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4e3iRT5XumvXDGy2Xa2XybTJsLtqkTiEQacjs2zq661K",
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
    shardingConf: ShardingConf.autoSharding(numShards = 8),
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
    storeNodes: @[
      "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj",
      "/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG",
      "/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3",
      "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7",
      "/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF",
      "/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV",
    ],
  )

# cluster-id=16 (Status networks)
# The `status.prod` and `status.staging` networks Status runs on. RLN is
# disabled. Auto-sharding uses the single shard 32, which Status publishes on;
# during its shard migration nodes also receive on shard 64.
proc statusNetworkConf(
    entryNodes: seq[string], storeNodes: seq[string]
): NetworkPresetConf =
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
    shardingConf: ShardingConf.autoSharding(numShards = 1, shards = @[32'u16]),
    extraListenShards: @[64'u16],
    enableKadDiscovery: false,
    kadBootstrapNodes: @[],
    mix: false,
    p2pReliability: false,
    discv5Discovery: true,
    discv5BootstrapNodes: @[],
    entryNodes: entryNodes,
    storeNodes: storeNodes,
  )

# Bootstrap is done through the status.prod DNS discovery enrtree plus the
# fleet boot nodes.
# Source: https://fleets.waku.org/ and each host's `/config.toml`.
proc StatusProdConf*(T: type NetworkPresetConf): NetworkPresetConf =
  statusNetworkConf(
    @[
      "enrtree://AMOJVZX4V6EXP7NTJPMAYJYST2QP6AJXYW76IU6VGJS7UVSNDYZG4@boot.prod.status.nodes.status.im",
      "/dns4/boot-01.do-ams3.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmAR24Mbb6VuzoyUiGx42UenDkshENVDj4qnmmbabLvo31",
      "/dns4/boot-01.gc-us-central1-a.status.prod.status.im/tcp/30303/p2p/16Uiu2HAm8mUZ18tBWPXDQsaF7PbCKYA35z7WB2xNZH2EVq1qS8LJ",
      "/dns4/boot-01.ac-cn-hongkong-c.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmGwcE8v7gmJNEWFtZtojYpPMTHy2jBLL6xRk33qgDxFWX",
    ],
    @[
      "/dns4/store-01.do-ams3.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmAUdrQ3uwzuE4Gy4D56hX6uLKEeerJAnhKEHZ3DxF1EfT",
      "/dns4/store-02.do-ams3.status.prod.status.im/tcp/30303/p2p/16Uiu2HAm9aDJPkhGxc2SFcEACTFdZ91Q5TJjp76qZEhq9iF59x7R",
      "/dns4/store-01.gc-us-central1-a.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmMELCo218hncCtTvC2Dwbej3rbyHQcR8erXNnKGei7WPZ",
      "/dns4/store-02.gc-us-central1-a.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmJnVR7ZzFaYvciPVafUXuYGLHPzSUigqAmeNw9nJUVGeM",
      "/dns4/store-01.ac-cn-hongkong-c.status.prod.status.im/tcp/30303/p2p/16Uiu2HAm2M7xs7cLPc3jamawkEqbr7cUJX11uvY7LxQ6WFUdUKUT",
      "/dns4/store-02.ac-cn-hongkong-c.status.prod.status.im/tcp/30303/p2p/16Uiu2HAm9CQhsuwPR54q27kNj9iaQVfyRzTGKrhFmr94oD8ujU6P",
    ],
  )

# Bootstrap is done through the status.staging DNS discovery enrtree plus the
# fleet boot node that resolves and accepts connections.
# Source: https://fleets.waku.org/.
proc StatusStagingConf*(T: type NetworkPresetConf): NetworkPresetConf =
  statusNetworkConf(
    @[
      "enrtree://AI4W5N5IFEUIHF5LESUAOSMV6TKWF2MB6GU2YK7PU4TYUGUNOCEPW@boot.staging.status.nodes.status.im",
      "/dns4/boot-01.do-ams3.status.staging.status.im/tcp/30303/p2p/16Uiu2HAmQE7FXQc6iZHdBzYfw3qCSDa9dLc1wsBJKoP4aZvztq2d",
    ],
    @[
      "/dns4/store-01.do-ams3.status.staging.status.im/tcp/30303/p2p/16Uiu2HAm3xVDaz6SRJ6kErwC21zBJEZjavVXg7VSkoWzaV1aMA3F",
      "/dns4/store-02.do-ams3.status.staging.status.im/tcp/30303/p2p/16Uiu2HAmCDSnT8oNpMR9HH6uipD71KstYuDCAQGpek9XDAVmqdEr",
    ],
  )

const MaxAllowedSubscribedShard* = 60

proc validateShards*(
    shardingConf: ShardingConf, shards: seq[uint16]
): Result[void, string] =
  if shards.len > MaxAllowedSubscribedShard:
    let msg =
      "too many shards: " & $shards.len & ", the maximum supported is " &
      $MaxAllowedSubscribedShard
    error "validateShards failed", error = msg
    return err(msg)

  case shardingConf.kind
  of StaticSharding:
    return ok()
  of AutoSharding:
    for shard in shards:
      if shard notin shardingConf.shards:
        let msg =
          "validateShards invalid shard: " & $shard & " when valid shards are: " &
          $shardingConf.shards
        error "validateShards failed", error = msg
        return err(msg)

  return ok()
