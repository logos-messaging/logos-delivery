import std/options, results
import
  logos_delivery/waku/[node/peer_manager, node/waku_node, waku_enr/sharding, common/enr/typed_record],
  ../testlib/[wakucore]

proc relayShards*(node: WakuNode): RelayShards =
  return node.enr.toTyped().get().relayShardingIndicesList().get()
