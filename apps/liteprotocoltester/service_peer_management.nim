{.push raises: [].}

import
  std/[options, net, sysrand, random, strformat, strutils, sequtils],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  libp2p/crypto/crypto,
  confutils,
  libp2p/wire

import
  tools/confutils/cli_args,
  waku/[
    common/enr,
    waku_node,
    node/peer_manager,
    waku_lightpush/common,
    waku_relay,
    waku_filter_v2,
    waku_peer_exchange/protocol,
    waku_core/multiaddrstr,
    waku_core/topics/pubsub_topic,
    waku_enr/capabilities,
    waku_enr/sharding,
  ],
  ./tester_config,
  ./diagnose_connections,
  ./lpt_metrics

logScope:
  topics = "service peer mgmt"

randomize()

proc translateToRemotePeerInfo*(peerAddress: string): Result[RemotePeerInfo, void] =
  var peerInfo: RemotePeerInfo
  var enrRec: enr.Record
  if enrRec.fromURI(peerAddress):
    trace "Parsed ENR", enrRec = $enrRec
    peerInfo = enrRec.toRemotePeerInfo().valueOr:
      error "failed to convert ENR to RemotePeerInfo", error = error
      return err()
  else:
    peerInfo = parsePeerInfo(peerAddress).valueOr:
      error "failed to parse node waku peer-exchange peerId", error = error
      return err()

  return ok(peerInfo)

## To retrieve peers from PeerExchange partner and return one randomly selected one
## among the ones successfully dialed
## Note: This is kept for future use.
proc selectRandomCapablePeer*(
    pm: PeerManager, codec: string, pubsubTopic: PubsubTopic
): Future[Option[RemotePeerInfo]] {.async.} =
  var cap = Capabilities.Filter
  if codec.contains("lightpush"):
    cap = Capabilities.Lightpush
  elif codec.contains("filter"):
    cap = Capabilities.Filter

  var supportivePeers = pm.switch.peerStore.getPeersByCapability(cap)

  trace "Found supportive peers count", count = supportivePeers.len()
  trace "Found supportive peers", supportivePeers = $supportivePeers
  if supportivePeers.len == 0:
    return none(RemotePeerInfo)

  var found = none(RemotePeerInfo)
  while found.isNone() and supportivePeers.len > 0:
    let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
    let randomPeer = supportivePeers[rndPeerIndex]

    info "Dialing random peer",
      idx = $rndPeerIndex, peer = constructMultiaddrStr(randomPeer)

    supportivePeers.delete(rndPeerIndex .. rndPeerIndex)

    let connOpt = pm.dialPeer(randomPeer, codec)
    if (await connOpt.withTimeout(10.seconds)):
      if connOpt.value().isSome():
        found = some(randomPeer)
        info "Dialing successful",
          peer = constructMultiaddrStr(randomPeer), codec = codec
      else:
        info "Dialing failed", peer = constructMultiaddrStr(randomPeer), codec = codec
    else:
      info "Timeout dialing service peer",
        peer = constructMultiaddrStr(randomPeer), codec = codec

  return found

# Debugging PX gathered peers connectivity
proc tryCallAllPxPeers*(
    pm: PeerManager, codec: string, pubsubTopic: PubsubTopic
): Future[Option[seq[RemotePeerInfo]]] {.async.} =
  var capability = Capabilities.Filter
  if codec.contains("lightpush"):
    capability = Capabilities.Lightpush
  elif codec.contains("filter"):
    capability = Capabilities.Filter

  var supportivePeers = pm.switch.peerStore.getPeersByCapability(capability)

  lpt_px_peers.set(supportivePeers.len)
  info "Found supportive peers count", count = supportivePeers.len()
  info "Found supportive peers", supportivePeers = $supportivePeers
  if supportivePeers.len == 0:
    return none(seq[RemotePeerInfo])

  var okPeers: seq[RemotePeerInfo] = @[]

  while supportivePeers.len > 0:
    let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
    let randomPeer = supportivePeers[rndPeerIndex]

    info "Dialing random peer",
      idx = $rndPeerIndex, peer = constructMultiaddrStr(randomPeer)

    supportivePeers.delete(rndPeerIndex, rndPeerIndex)

    let connOpt = pm.dialPeer(randomPeer, codec)
    if (await connOpt.withTimeout(10.seconds)):
      if connOpt.value().isSome():
        okPeers.add(randomPeer)
        info "Dialing successful",
          peer = constructMultiaddrStr(randomPeer),
          agent = randomPeer.getAgent(),
          codec = codec
        lpt_dialed_peers.inc(labelValues = [randomPeer.getAgent()])
      else:
        lpt_dial_failures.inc(labelValues = [randomPeer.getAgent()])
        error "Dialing failed",
          peer = constructMultiaddrStr(randomPeer),
          agent = randomPeer.getAgent(),
          codec = codec
    else:
      lpt_dial_failures.inc(labelValues = [randomPeer.getAgent()])
      error "Timeout dialing service peer",
        peer = constructMultiaddrStr(randomPeer),
        agent = randomPeer.getAgent(),
        codec = codec

  var okPeersStr: string = ""
  for idx, peer in okPeers:
    okPeersStr.add(
      "    " & $idx & ". | " & constructMultiaddrStr(peer) & " | agent: " &
        peer.getAgent() & " | protos: " & $peer.protocols & " | caps: " &
        $peer.enr.map(getCapabilities) & "\n"
    )
  echo "PX returned peers found callable for " & codec & " / " & $capability & ":\n"
  echo okPeersStr

  return some(okPeers)

proc pxLookupServiceNode*(
    node: WakuNode, conf: LiteProtocolTesterConf
): Future[Result[bool, void]] {.async.} =
  let codec: string = conf.getCodec()

  if node.wakuPeerExchange.isNil():
    let peerExchangeNode = translateToRemotePeerInfo(conf.bootstrapNode).valueOr:
      error "Failed to parse bootstrap node - cannot use PeerExchange.",
        node = conf.bootstrapNode
      return err()
    info "PeerExchange node", peer = constructMultiaddrStr(peerExchangeNode)
    node.peerManager.addServicePeer(peerExchangeNode, WakuPeerExchangeCodec)

    try:
      await node.mountPeerExchange(some(conf.clusterId))
    except CatchableError:
      error "failed to mount waku peer-exchange protocol",
        error = getCurrentExceptionMsg()
      return err()

  var trialCount = 5
  while trialCount > 0:
    let futPeers = node.fetchPeerExchangePeers(conf.reqPxPeers)
    if not await futPeers.withTimeout(30.seconds):
      notice "Cannot get peers from PX", round = 5 - trialCount
    else:
      futPeers.value().isOkOr:
        info "PeerExchange reported error", error = futPeers.read().error
        return err()

    if conf.testPeers:
      let peersOpt =
        await tryCallAllPxPeers(node.peerManager, codec, conf.getPubsubTopic())
      if peersOpt.isSome():
        info "Found service peers for codec",
          codec = codec, peer_count = peersOpt.get().len()
        return ok(peersOpt.get().len > 0)
    else:
      let peerOpt =
        await selectRandomCapablePeer(node.peerManager, codec, conf.getPubsubTopic())
      if peerOpt.isSome():
        info "Found service peer for codec", codec = codec, peer = peerOpt.get()
        return ok(true)

    await sleepAsync(5.seconds)
    trialCount -= 1

  return err()

var alreadyUsedServicePeers {.threadvar.}: seq[RemotePeerInfo]

## Select service peers by codec from peer store randomly.
proc selectRandomServicePeer*(
    pm: PeerManager, actualPeer: Option[RemotePeerInfo], codec: string
): Result[RemotePeerInfo, void] =
  if actualPeer.isSome():
    alreadyUsedServicePeers.add(actualPeer.get())

  let supportivePeers = pm.switch.peerStore.getPeersByProtocol(codec).filterIt(
      it notin alreadyUsedServicePeers
    )
  if supportivePeers.len == 0:
    return err()

  let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
  return ok(supportivePeers[rndPeerIndex])
