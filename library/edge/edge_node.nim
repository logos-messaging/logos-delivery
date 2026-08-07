## Slim edge node: just the pieces a browser edge node needs for lightpush +
## filter — a libp2p Switch (browser-WS), a PeerManager, and the two light
## protocol clients. Deliberately NOT `WakuNode`/`Waku`, whose field types pull
## relay/store/archive/rln (rln/zerokit can't compile to wasm at all).

{.push raises: [].}

import std/options
import chronos, chronicles, results
import libp2p/[switch, crypto/crypto]
import
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/waku_core/codecs,
  logos_delivery/waku/waku_metadata,
  logos_delivery/waku/node/peer_manager/peer_manager,
  logos_delivery/waku/waku_filter_v2/client as filter_client,
  logos_delivery/waku/waku_lightpush/client as lightpush_client,
  logos_delivery/waku/waku_store/client as store_client
import ./edge_factory

# The Status shards cluster (status-app / Status fleet runs on cluster 16), plus
# the shard our example traffic uses. Service nodes run the metadata protocol and
# disconnect peers that don't advertise a matching cluster, so the edge node must
# mount it too.
const
  DefaultEdgeClusterId* = 16'u32
  DefaultEdgeShards* = @[32'u16]

type EdgeNode* = ref object
  switch*: Switch
  peerManager*: PeerManager
  rng*: ref HmacDrbgContext
  wakuFilterClient*: filter_client.WakuFilterClient
  wakuLightpushClient*: lightpush_client.WakuLightPushClient
  wakuStoreClient*: store_client.WakuStoreClient
  metadata*: WakuMetadata
  # The dialed service node. An edge node talks to one known server, so we use
  # it directly for lightpush/filter rather than relying on identify to populate
  # the peer store (identify timing/shard-pruning makes selectPeer unreliable here).
  serviceNode*: Option[RemotePeerInfo]
  # An optional dedicated store peer. Service nodes don't necessarily serve store
  # (a bootstrap node usually doesn't), so history queries can be pointed elsewhere;
  # when unset we fall back to the service node.
  storeNode*: Option[RemotePeerInfo]

proc newEdgeNode*(
    rng: ref HmacDrbgContext,
    privKey: crypto.PrivateKey,
    clusterId: uint32 = DefaultEdgeClusterId,
    shards: seq[uint16] = DefaultEdgeShards,
): EdgeNode {.raises: [LPError].} =
  let switch = newEdgeSwitch(rng, privKey)
  let node = EdgeNode(switch: switch, peerManager: PeerManager.new(switch), rng: rng)

  # Mount the metadata protocol so service nodes can verify our cluster/shards and
  # keep us connected. We deliberately do NOT set peerManager.wakuMetadata: that
  # would make us run refreshPeerMetadata on connect and disconnect the server if
  # our own metadata round-trip hiccups — the server querying us is sufficient.
  let metadata = WakuMetadata.new(
    clusterId,
    proc(): seq[uint16] {.closure, gcsafe, raises: [].} =
      shards,
  )
  let mountRes = catch:
    node.switch.mount(metadata, protocolMatcher(WakuMetadataCodec))
  mountRes.isOkOr:
    raise (ref LPError)(msg: "failed to mount metadata: " & error.msg)
  # Kept so the caller can START it. Mounting alone registers the codec but leaves the
  # protocol with no running handler, so the service node's metadata request reads a
  # closed stream and drops us seconds after connect — taking every later lightpush,
  # store and filter stream with it.
  node.metadata = metadata

  return node

proc mountFilterClient*(node: EdgeNode) {.async: (raises: []).} =
  ## Mirrors waku_node/filter.nim:mountFilterClient, on the slim node.
  if not node.wakuFilterClient.isNil():
    return
  node.wakuFilterClient = WakuFilterClient.new(node.peerManager, node.rng)
  try:
    await node.wakuFilterClient.start()
  except CatchableError:
    error "failed to start wakuFilterClient", error = getCurrentExceptionMsg()
  # Mount on the switch so the service node can open inbound filter-push streams
  # to deliver matched messages. Without this the server's push stream is rejected.
  try:
    node.switch.mount(
      node.wakuFilterClient, protocolMatcher(WakuFilterSubscribeCodec)
    )
  except LPError:
    error "failed to mount wakuFilterClient", error = getCurrentExceptionMsg()

proc mountLightPushClient*(node: EdgeNode) =
  ## Mirrors waku_node/lightpush.nim client mount, on the slim node. Uses the v3
  ## lightpush protocol (`/vac/waku/lightpush/3.0.0`) that the Status fleet serves.
  if node.wakuLightpushClient.isNil():
    node.wakuLightpushClient = WakuLightPushClient.new(node.peerManager, node.rng)

proc startMetadata*(node: EdgeNode) {.async: (raises: []).} =
  ## Start the mounted metadata protocol. Without this the handler never runs: the server
  ## queries our cluster/shards, the read fails, and it disconnects us with
  ## "waku metatdata request failed: read failed: Stream Closed!".
  if node.metadata.isNil():
    return
  try:
    await node.metadata.start()
  except CatchableError:
    error "failed to start metadata protocol", error = getCurrentExceptionMsg()

proc mountStoreClient*(node: EdgeNode) =
  ## Store is client-only here: we dial OUT on `/vac/waku/store-query/3.0.0`, so
  ## unlike filter (which needs an inbound push stream) there is nothing to mount
  ## on the switch — constructing the client is the whole job.
  if node.wakuStoreClient.isNil():
    node.wakuStoreClient = WakuStoreClient.new(node.peerManager, node.rng)
