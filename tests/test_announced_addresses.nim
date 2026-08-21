{.used.}

## libp2p commits the final announced addresses into peerInfo after
## the address mappers run. These tests check that node.announcedAddresses
## and the ENR multiaddrs field copy that committed set.

import results
import std/[net, sequtils, strutils]
import testutils/unittests, chronos
import libp2p/[multiaddress, peerinfo, switch, wire]
import ../logos_delivery/waku/node/waku_node
import ./testlib/[common, wakucore, wakunode]

suite "Announced addresses":
  asyncTest "the resolved base reaches peerInfo and the API projection":
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    await node.start()
    check:
      node.announcedAddresses.len > 0
      node.announcedAddresses == node.switch.peerInfo.addrs
      node.announcedAddresses.allIt("/tcp/0" notin $it and "/udp/0/" notin $it)
      node.announcedAddresses.allIt("0.0.0.0" notin $it)
    await node.stop()

  asyncTest "a loopback bind stays loopback in the base":
    ## Rewriting loopback to the LAN IP once crashed the test suite
    ## because it announces endpoints nothing listens on.
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.start()
    check:
      node.announcedAddresses.len > 0
      node.announcedAddresses.allIt("/ip4/127.0.0.1/" in $it)
    await node.stop()

  asyncTest "an operator host containing the wildcard substring survives intact":
    ## The host string contains "0.0.0.0". Text replacement corrupted it.
    ## Matching the parsed IP keeps it unchanged.
    let tricky = MultiAddress.init("/ip4/10.0.0.0/tcp/60123").get()
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[tricky],
    )
    await node.start()
    check:
      tricky in node.announcedAddresses
    await node.stop()
