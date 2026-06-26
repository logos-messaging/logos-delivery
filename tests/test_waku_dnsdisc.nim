import libp2p/crypto/rng
{.used.}

import
  std/[sequtils, tables],
  results,
  stew/base32,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  eth/keys,
  dnsdisc/builder
import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_node,
  logos_delivery/waku/discovery/waku_dnsdisc,
  ./testlib/common,
  ./testlib/wakucore,
  ./testlib/wakunode,
  ./waku_enr/utils

suite "Waku DNS Discovery":
  asyncTest "Waku DNS Discovery end-to-end":
    ## Tests integrated DNS discovery, from building
    ## the tree to connecting to discovered nodes

    let
      bindIp = parseIpAddress("127.0.0.1")
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, bindIp, Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, bindIp, Port(0))
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, bindIp, Port(0))

    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await allFutures([node1.start(), node2.start(), node3.start()])

    let
      enr1 = newTestEnrRecord(nodeKey1, $bindIp, uint16(node1.boundTcpPort()), 0)
      enr2 = newTestEnrRecord(nodeKey2, $bindIp, uint16(node2.boundTcpPort()), 0)
      enr3 = newTestEnrRecord(nodeKey3, $bindIp, uint16(node3.boundTcpPort()), 0)

    # Build and sign tree
    var tree = buildTree(
        1, # Seq no
        @[enr1, enr2, enr3], # ENR entries
        @[],
      )
      .get() # No link entries

    let treeKeys = keys.KeyPair.random(keys.newRng()[])

    # Sign tree
    check:
      tree.signTree(treeKeys.seckey()).isOk()

    # Create TXT records at domain
    let
      domain = "testnodes.aq"
      zoneTxts = tree.buildTXT(domain).get()
      username = Base32.encode(treeKeys.pubkey().toRawCompressed())
      location = LinkPrefix & username & "@" & domain
        # See EIP-1459: https://eips.ethereum.org/EIPS/eip-1459

    # Create a resolver for the domain

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      return zoneTxts[domain]

    # Create Waku DNS discovery client on a new Waku v2 node using the resolver

    let
      nodeKey4 = generateSecp256k1Key()
      node4 = newTestWakuNode(nodeKey4, bindIp, Port(0))

    (await node4.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node4.start()

    var wakuDnsDisc = WakuDnsDiscovery.init(location, resolver).get()

    let res = await wakuDnsDisc.findPeers()

    check:
      # We have discovered all three nodes
      res.isOk()
      res[].len == 3
      res[].mapIt(it.peerId).contains(node1.switch.peerInfo.peerId)
      res[].mapIt(it.peerId).contains(node2.switch.peerInfo.peerId)
      res[].mapIt(it.peerId).contains(node3.switch.peerInfo.peerId)

    # Connect to discovered nodes
    await node4.connectToNodes(res[])

    check:
      # We have successfully connected to all discovered nodes
      node4.peerManager.switch.peerStore.peers().anyIt(
        it.peerId == node1.switch.peerInfo.peerId
      )
      node4.peerManager.switch.peerStore.connectedness(node1.switch.peerInfo.peerId) ==
        Connected
      node4.peerManager.switch.peerStore.peers().anyIt(
        it.peerId == node2.switch.peerInfo.peerId
      )
      node4.peerManager.switch.peerStore.connectedness(node2.switch.peerInfo.peerId) ==
        Connected
      node4.peerManager.switch.peerStore.peers().anyIt(
        it.peerId == node3.switch.peerInfo.peerId
      )
      node4.peerManager.switch.peerStore.connectedness(node3.switch.peerInfo.peerId) ==
        Connected

    await allFutures([node1.stop(), node2.stop(), node3.stop(), node4.stop()])
