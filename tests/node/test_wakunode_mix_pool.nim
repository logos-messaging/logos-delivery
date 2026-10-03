{.used.}

## The mix pool keeps its mix nodes when the peer store deletes them.

import
  std/[sequtils, tables],
  testutils/unittests,
  chronos,
  results,
  libp2p/[multiaddress, peerid, peerinfo, peerstore, switch],
  libp2p/crypto/crypto,
  libp2p_mix/[curve25519, mix_node, pool]
import
  logos_delivery/waku/[waku_core, waku_node, waku_mix],
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  ../testlib/[testasync, wakucore, wakumix]

suite "Waku Mix - the pool keeps its mix nodes":
  asyncTest "a configured node stays in the pool after a peer store delete":
    let configured = bootnode("/ip4/1.2.3.4/tcp/30303")
    let node = await mixNode(bootnodes = @[configured])
    let peerId = configured.peerId
    let before = node.wakuMix.nodePool.get(peerId).expect("pool entry")

    node.switch.peerStore.delete(peerId)
    check:
      peerId notin node.switch.peerStore[MixPubKeyBook]
      node.inPool(peerId)
    let after = node.wakuMix.nodePool.get(peerId).expect("pool entry")
    check:
      after.multiAddr == before.multiAddr
      after.mixPubKey == before.mixPubKey

    # A configured node does not expire.
    node.wakuMix.pool.discoveredTtl = ZeroDuration
    node.wakuMix.pool.maintain()
    check node.inPool(peerId)

  asyncTest "a send works after the peer store deletes each configured node":
    let net = await startMixNodes()
    let sender = await addNatSender(net.infos)
    defer:
      await net.stop(@[sender])
    await net.disconnectAll(sender)
    for info in net.infos:
      sender.switch.peerStore.delete(info.peerId)
    check sender.getMixNodePoolSize() == MixNodeCount

    let outcome = await net.send(sender, "after-delete")
    check:
      outcome.acked
      await net.published(outcome)

  asyncTest "a discovered node stays after a peer store delete, and expires later":
    let node = await mixNode()
    let peerId = node.discover(@["/ip4/1.1.3.3/tcp/30303"])

    node.switch.peerStore.delete(peerId)
    node.wakuMix.pool.maintain()
    check:
      node.inPool(peerId)
      $node.hopOf(peerId) == "/ip4/1.1.3.3/tcp/30303"

    node.wakuMix.pool.discoveredTtl = ZeroDuration
    node.wakuMix.pool.maintain()
    check not node.inPool(peerId)

  asyncTest "the pool loop removes an old discovered node while mix runs":
    let node = await startMixNode(poolLoopInterval = chronos.milliseconds(100))
    defer:
      await node.stop()
    node.wakuMix.pool.discoveredTtl = chronos.milliseconds(300)
    let peerId = node.discover(@["/ip4/1.1.3.3/tcp/30303"])
    check node.inPool(peerId)

    checkUntilTimeout:
      not node.inPool(peerId)

  asyncTest "a peer store delete of a connected peer keeps its pool entry":
    let target = await startNodeWithoutMix()
    let node = await startMixNode()
    defer:
      await node.stop()
      await target.stop()
    let targetId = node.discover(@[target.tcpAddress()], target.peerInfo.peerId)
    await node.switch.connect(targetId, target.peerInfo.addrs)
    let protocols = node.switch.peerStore[ProtoBook][targetId]
    check protocols.len > 0

    node.switch.peerStore.delete(targetId)
    check:
      node.inPool(targetId)
      $node.hopOf(targetId) == target.tcpAddress()
      protocols.allIt(node.wakuMix.pool.hasProtocol(targetId, it))

    # On a connection, the list in the peer store replaces the copy.
    node.switch.peerStore[ProtoBook][targetId] = @["/test/only/1"]
    check:
      node.wakuMix.pool.hasProtocol(targetId, "/test/only/1")
      not node.wakuMix.pool.hasProtocol(targetId, protocols[0])

    # A connected node does not expire.
    node.wakuMix.pool.discoveredTtl = ZeroDuration
    node.wakuMix.pool.maintain()
    check node.inPool(targetId)

  asyncTest "discovery updates a configured node, and a delete changes no hop":
    let configured = bootnode("/ip4/1.2.3.4/tcp/30303")
    let node = await mixNode(bootnodes = @[configured])
    let peerId = configured.peerId

    node.discover(@["/ip4/1.2.3.9/tcp/30303"], peerId)
    let discovered = node.switch.peerStore[MixPubKeyBook][peerId]
    check:
      discovered != configured.pubKey
      # The address from discovery comes before the configured address.
      $node.hopOf(peerId) == "/ip4/1.2.3.9/tcp/30303"
      node.wakuMix.nodePool.get(peerId).expect("pool entry").mixPubKey == discovered

    # The address that this node dialed last comes first.
    node.switch.peerStore[LastSeenOutboundBook][peerId] =
      Opt.some(MultiAddress.init("/ip4/1.2.3.10/tcp/30303").tryGet())
    check $node.hopOf(peerId) == "/ip4/1.2.3.10/tcp/30303"

    node.switch.peerStore.delete(peerId)
    check:
      $node.hopOf(peerId) == "/ip4/1.2.3.10/tcp/30303"
      node.wakuMix.nodePool.get(peerId).expect("pool entry").mixPubKey == discovered

  asyncTest "the hop carries the configured address when discovery gives only a name":
    ## Fleet nodes announce a dns4 name, which a hop cannot carry.
    let configured = bootnode("/ip4/1.2.3.4/tcp/30303")
    let node = await mixNode(bootnodes = @[configured])
    let peerId = configured.peerId

    node.switch.peerStore.delete(peerId)
    node.discover(@["/dns4/node.test/tcp/30303"], peerId)
    check node.inPool(peerId)
    if node.inPool(peerId):
      check $node.hopOf(peerId) == "/ip4/1.2.3.4/tcp/30303"

  asyncTest "a configured node keeps its copies when the configuration adds it again":
    let configured = bootnode("/ip4/1.2.3.4/tcp/30303")
    let node = await mixNode(bootnodes = @[configured])
    let peerId = configured.peerId
    node.switch.peerStore[ProtoBook][peerId] = @["/test/exit/1"]
    node.switch.peerStore.delete(peerId)

    # `addBootNodes` adds the entries that a name lookup resolved after the mount.
    node.wakuMix.addBootNodes(@[configured])
    check node.wakuMix.pool.hasProtocol(peerId, "/test/exit/1")

  asyncTest "a record without a mix key does not keep a node in the pool":
    ## At the limit of discovered nodes, the node with the oldest record goes.
    let node = await mixNode()
    node.wakuMix.pool.maxDiscovered = 2
    let active = node.discover(@["/ip4/1.1.3.4/tcp/30303"])
    let silent = node.discover(@["/ip4/1.1.3.3/tcp/30303"])

    # A new record with a mix key makes `active` newer than `silent`.
    node.discover(@["/ip4/1.1.3.4/tcp/30303"], active)
    # The record of a node that stopped mix has no mix key.
    node.peerManager.addPeer(
      RemotePeerInfo.init(
        silent, @[MultiAddress.init("/ip4/1.1.3.5/tcp/30303").tryGet()]
      )
    )
    node.discover(@["/ip4/1.1.3.6/tcp/30303"])
    check:
      not node.inPool(silent)
      node.inPool(active)

  asyncTest "this node is never a pool member":
    let node = await mixNode()
    let own = node.switch.peerInfo
    let keys = generateKeyPair().expect("mix key pair")
    node.wakuMix.pool.add(
      MixPubInfo.init(
        own.peerId,
        MultiAddress.init("/ip4/1.2.3.4/tcp/30303").tryGet(),
        keys.publicKey,
        own.publicKey.skkey,
      )
    )
    # The peer manager skips this node, so write the peer store directly.
    node.switch.peerStore.addPeer(
      RemotePeerInfo.init(
        own.peerId,
        @[MultiAddress.init("/ip4/1.2.3.4/tcp/30303").tryGet()],
        mixPubKey = Opt.some(keys.publicKey),
      )
    )
    check:
      node.switch.peerStore[MixPubKeyBook][own.peerId] == keys.publicKey
      not node.inPool(own.peerId)
      node.getMixNodePoolSize() == 0

  asyncTest "at the limit of discovered nodes, a node that is not a pool member goes first, then the oldest":
    let configured =
      @[bootnode("/ip4/1.2.3.4/tcp/30303"), bootnode("/ip4/1.2.3.5/tcp/30303")]
    let node = await mixNode(bootnodes = configured)
    node.wakuMix.pool.maxDiscovered = 2
    let older = node.discover(@["/ip4/1.1.3.1/tcp/30303"])
    # The policy refuses this address, so the node is not a pool member.
    node.discover(@["/ip4/192.168.3.1/tcp/30303"])

    let newer = node.discover(@["/ip4/1.1.3.3/tcp/30303"])
    check:
      node.inPool(older)
      node.inPool(newer)

    let newest = node.discover(@["/ip4/1.1.3.4/tcp/30303"])
    check:
      not node.inPool(older)
      node.inPool(newer)
      node.inPool(newest)
      configured.allIt(node.inPool(it.peerId))
      node.getMixNodePoolSize() == 4

  asyncTest "a discovered peer keeps its expired address, and expires later":
    let node = await mixNode()
    let peerId = node.discover(@["/ip4/1.1.3.3/tcp/30303"])
    check node.getMixNodePoolSize() == 1

    let book = node.switch.peerStore[AddressBook]
    var entries = book.book[peerId]
    for entry in entries.mitems:
      entry.lastUpdated = Moment.now() - chronos.hours(2)
    book.book[peerId] = entries # No handler runs for a direct write.
    # A protocol update makes the pool read the books again.
    node.switch.peerStore[ProtoBook][peerId] = @["/test/1.0.0"]
    check:
      node.switch.peerStore[AddressBook][peerId].len == 0
      $node.hopOf(peerId) == "/ip4/1.1.3.3/tcp/30303"

    node.wakuMix.pool.discoveredTtl = ZeroDuration
    node.wakuMix.pool.maintain()
    check node.getMixNodePoolSize() == 0
