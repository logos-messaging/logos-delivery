{.used.}

import
  std/strutils,
  results,
  testutils/unittests,
  libp2p/multiaddress,
  libp2p/peerid,
  libp2p/errors,
  confutils/toml/std/net
import logos_delivery/waku/[waku_core, waku_enr], ../testlib/wakucore

procSuite "Waku Core - Peers":
  test "Peer info parses correctly":
    ## Given
    let address =
      "/ip4/127.0.0.1/tcp/65002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value

    ## Then
    check:
      $(remotePeerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(remotePeerInfo.addrs[0][0].tryGet()) == "/ip4/127.0.0.1"
      $(remotePeerInfo.addrs[0][1].tryGet()) == "/tcp/65002"

  test "DNS multiaddrs parsing - dns peer":
    ## Given
    let address =
      "/dns/localhost/tcp/65012/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dnsPeerRes = parsePeerInfo(address)
    require dnsPeerRes.isOk()

    let dnsPeer = dnsPeerRes.value

    ## Then
    check:
      $(dnsPeer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dnsPeer.addrs[0][0].tryGet()) == "/dns/localhost"
      $(dnsPeer.addrs[0][1].tryGet()) == "/tcp/65012"

  test "DNS multiaddrs parsing - dnsaddr peer":
    ## Given
    let address =
      "/dnsaddr/localhost/tcp/65022/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dnsAddrPeerRes = parsePeerInfo(address)
    require dnsAddrPeerRes.isOk()

    let dnsAddrPeer = dnsAddrPeerRes.value

    ## Then
    check:
      $(dnsAddrPeer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dnsAddrPeer.addrs[0][0].tryGet()) == "/dnsaddr/localhost"
      $(dnsAddrPeer.addrs[0][1].tryGet()) == "/tcp/65022"

  test "DNS multiaddrs parsing - dns4 peer":
    ## Given
    let address =
      "/dns4/localhost/tcp/65032/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dns4PeerRes = parsePeerInfo(address)
    require dns4PeerRes.isOk()

    let dns4Peer = dns4PeerRes.value

    # Then
    check:
      $(dns4Peer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dns4Peer.addrs[0][0].tryGet()) == "/dns4/localhost"
      $(dns4Peer.addrs[0][1].tryGet()) == "/tcp/65032"

  test "DNS multiaddrs parsing - dns6 peer":
    ## Given
    let address =
      "/dns6/localhost/tcp/65042/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dns6PeerRes = parsePeerInfo(address)
    require dns6PeerRes.isOk()

    let dns6Peer = dns6PeerRes.value

    ## Then
    check:
      $(dns6Peer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dns6Peer.addrs[0][0].tryGet()) == "/dns6/localhost"
      $(dns6Peer.addrs[0][1].tryGet()) == "/tcp/65042"

  test "Multiaddr parsing should fail with invalid address":
    ## Given
    let address = "/p2p/$UCH GIBBER!SH"

    ## Then
    check:
      parsePeerInfo(address).isErr()

  test "Multiaddr parsing should fail with leading whitespace":
    ## Given
    let address =
      " /ip4/127.0.0.1/tcp/65062/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## Then
    check:
      parsePeerInfo(address).isErr()

  test "Multiaddr parsing should fail with trailing whitespace":
    ## Given
    let address =
      "/ip4/127.0.0.1/tcp/65072/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc "

    ## Then
    check:
      parsePeerInfo(address).isErr()

  test "Multiaddress parsing should fail with invalid IP address":
    ## Given
    let address =
      "/ip4/127.0.0.0.1/tcp/65082/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## Then
    check:
      parsePeerInfo(address).isErr()

  test "Multiaddress parsing should fail with no peer ID":
    ## Given
    let address = "/ip4/127.0.0.1/tcp/65092"

    # Then
    check:
      parsePeerInfo(address).isErr()

  test "Multiaddress parsing should fail with unsupported transport":
    ## Given
    let address =
      "/ip4/127.0.0.1/udp/65102/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## Then
    check:
      parsePeerInfo(address).isErr()

  test "QUIC-v1 peer info parses correctly":
    ## Given
    let address =
      "/ip4/127.0.0.1/udp/61002/quic-v1/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value

    ## Then
    check:
      $(remotePeerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      remotePeerInfo.addrs.len == 1
      $(remotePeerInfo.addrs[0]) == "/ip4/127.0.0.1/udp/61002/quic-v1"

  test "QUIC-v1 peer info parses correctly - ip6":
    ## Given
    let address =
      "/ip6/::1/udp/65112/quic-v1/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value

    ## Then
    check:
      $(remotePeerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(remotePeerInfo.addrs[0]) == "/ip6/::1/udp/65112/quic-v1"

  test "DNS multiaddrs parsing - dns4 QUIC-v1 peer":
    ## Given
    let address =
      "/dns4/localhost/udp/65033/quic-v1/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dns4PeerRes = parsePeerInfo(address)
    require dns4PeerRes.isOk()

    let dns4Peer = dns4PeerRes.value

    ## Then
    check:
      $(dns4Peer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dns4Peer.addrs[0]) == "/dns4/localhost/udp/65033/quic-v1"

  test "Secure WebSocket peer info keeps the tls part":
    ## The WebSocket transport uses the tls component to select TLS.
    ## Removing it produces a plaintext WebSocket address.
    let address =
      "/dns4/localhost/tcp/443/tls/ws/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    let peerRes = parsePeerInfo(address)
    check peerRes.isOk()

    let peer = peerRes.get(RemotePeerInfo())
    check:
      $(peer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      peer.addrs == @[MultiAddress.init("/dns4/localhost/tcp/443/tls/ws").get()]

  test "TLS without WebSocket is rejected, not accepted as TCP":
    ## TCP/TLS without WebSocket does not match a supported transport.
    ## Dropping tls incorrectly makes the address match plain TCP.
    let address =
      "/dns4/localhost/tcp/443/tls/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    let res = parsePeerInfo(address)
    check res.errorOr("accepted") == "invalid multiaddress: no supported transport found"

  test "Peer address list parses a single address":
    ## Given
    let address =
      "/ip4/127.0.0.1/tcp/65002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let remotePeerInfoRes = parsePeerAddrList(address)
    require remotePeerInfoRes.isOk()

    ## Then
    let remotePeerInfo = remotePeerInfoRes.value
    check:
      $(remotePeerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      remotePeerInfo.addrs.len == 1

  test "Peer address list keeps every address of the peer":
    ## Given
    let addresses =
      "/ip4/127.0.0.1/tcp/65002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc," &
      "/ip4/10.0.0.1/tcp/65003/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let remotePeerInfoRes = parsePeerAddrList(addresses)
    require remotePeerInfoRes.isOk()

    ## Then
    let remotePeerInfo = remotePeerInfoRes.value
    check:
      $(remotePeerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      remotePeerInfo.addrs.len == 2
      $(remotePeerInfo.addrs[0][0].tryGet()) == "/ip4/127.0.0.1"
      $(remotePeerInfo.addrs[1][0].tryGet()) == "/ip4/10.0.0.1"

  test "Peer address list keeps a TCP and a QUIC-v1 address of the same peer":
    ## Given
    let addresses =
      "/ip4/127.0.0.1/tcp/65002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc," &
      "/ip4/127.0.0.1/udp/65002/quic-v1/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let remotePeerInfoRes = parsePeerAddrList(addresses)
    require remotePeerInfoRes.isOk()

    ## Then
    let remotePeerInfo = remotePeerInfoRes.value
    check:
      remotePeerInfo.addrs.len == 2
      $(remotePeerInfo.addrs[0]) == "/ip4/127.0.0.1/tcp/65002"
      $(remotePeerInfo.addrs[1]) == "/ip4/127.0.0.1/udp/65002/quic-v1"

  test "Peer address list tolerates whitespace and empty entries":
    ## Given
    let addresses =
      " /ip4/127.0.0.1/tcp/65002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc , ," &
      " /ip4/10.0.0.1/tcp/65003/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc "

    ## Then
    let remotePeerInfoRes = parsePeerAddrList(addresses)
    require remotePeerInfoRes.isOk()
    check:
      remotePeerInfoRes.value.addrs.len == 2

  test "Peer address list rejects addresses of different peers":
    ## Given
    let addresses =
      "/ip4/127.0.0.1/tcp/65002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc," &
      "/ip4/10.0.0.1/tcp/65003/p2p/16Uiu2HAmVGHwfEi4kiNvuK6xVwGB2WeHoZNU1FgTUgZ8QvxiMqQw"

    ## Then
    check:
      parsePeerAddrList(addresses).isErr()

  test "Peer address list rejects an empty list":
    ## Then
    check:
      parsePeerAddrList("").isErr()
      parsePeerAddrList(" , ").isErr()

  const RelayId = "16Uiu2HAmCzWcYBCw3xKW8De16X9wtcbQrqD8x7CRRv4xpsFJ4oN8"
  const TargetId = "16Uiu2HAm2eqzqp6xn32fzgGi8K4BuF88W4Xy6yxsmDcW8h1gj6ie"

  proc circuit(relayPart: string): string =
    ## A circuit relay address: the address of the relay, then the circuit and
    ## the target peer id.
    relayPart & "/p2p/" & RelayId & "/p2p-circuit/p2p/" & TargetId

  test "Circuit relay address parses to the target behind a TCP relay":
    ## Given
    let address = circuit("/ip4/162.19.247.156/tcp/60010")

    ## When
    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value

    ## Then
    check:
      $(remotePeerInfo.peerId) == TargetId
      remotePeerInfo.addrs.len == 1
      $(remotePeerInfo.addrs[0]) ==
        "/ip4/162.19.247.156/tcp/60010/p2p/" & RelayId & "/p2p-circuit"

  test "Circuit relay address parses with a QUIC-v1 relay":
    ## The relay part is a peer address. The node can dial it with each of its
    ## transports.
    let address = circuit("/ip4/162.19.247.156/udp/60010/quic-v1")

    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value
    check:
      $(remotePeerInfo.peerId) == TargetId
      $(remotePeerInfo.addrs[0]) ==
        "/ip4/162.19.247.156/udp/60010/quic-v1/p2p/" & RelayId & "/p2p-circuit"

  test "Circuit relay address parses with a relay named by DNS":
    ## Regression: the old pattern accepted only hex digits, colons and dots in
    ## the relay host. Thus the parser rejected a name with a different letter.
    let address = circuit("/dns4/relay.example.com/tcp/60010")

    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value
    check:
      $(remotePeerInfo.peerId) == TargetId
      $(remotePeerInfo.addrs[0]) ==
        "/dns4/relay.example.com/tcp/60010/p2p/" & RelayId & "/p2p-circuit"

  test "Circuit relay address parses with a WebSocket relay":
    ## Regression: the old pattern accepted only `/wss/<port>`. A multiaddr has
    ## the shape `/tcp/<port>/wss`. Thus the parser rejected each WebSocket relay.
    let address = circuit("/ip4/162.19.247.156/tcp/443/wss")

    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value
    check:
      $(remotePeerInfo.peerId) == TargetId
      $(remotePeerInfo.addrs[0]) ==
        "/ip4/162.19.247.156/tcp/443/wss/p2p/" & RelayId & "/p2p-circuit"

  test "Circuit relay address parses with an IPv6 relay":
    let address = circuit("/ip6/2001:db8::1/tcp/60010")

    let remotePeerInfoRes = parsePeerInfo(address)
    require remotePeerInfoRes.isOk()

    let remotePeerInfo = remotePeerInfoRes.value
    check:
      $(remotePeerInfo.peerId) == TargetId
      $(remotePeerInfo.addrs[0]) ==
        "/ip6/2001:db8::1/tcp/60010/p2p/" & RelayId & "/p2p-circuit"

  test "Circuit relay address is rejected when the relay part has no transport":
    ## UDP without QUIC is unsupported. The error prefix includes the complete
    ## circuit-relay address between colon separators.
    let address = circuit("/ip4/162.19.247.156/udp/60010")
    let error = parsePeerInfo(address).errorOr("accepted")
    check error.startsWith("relay part of p2p-circuit address: " & address & ": ")

  test "Circuit relay address is rejected without the relay peer id":
    let address = "/ip4/162.19.247.156/tcp/60010/p2p-circuit/p2p/" & TargetId
    check parsePeerInfo(address).isErr()

  test "Circuit relay address is rejected when nothing comes before the circuit":
    ## Reject an empty relay prefix before constructing its multiaddress.
    let address = "/p2p-circuit/p2p/" & TargetId
    let error = parsePeerInfo(address).errorOr("accepted")
    check error == "no relay part before /p2p-circuit/p2p/ in: " & address

  test "Circuit relay address is rejected with an incorrect target peer id":
    let address =
      "/ip4/162.19.247.156/tcp/60010/p2p/" & RelayId & "/p2p-circuit/p2p/not-a-peer-id"
    check parsePeerInfo(address).isErr()

  test "Circuit relay address is rejected when the relay peer id is not last in the relay part":
    ## The relay transport reads the relay peer id from the part before
    ## /p2p-circuit. If the shape is different, the dial is not possible. Thus
    ## the parser rejects it.
    let address =
      "/ip4/162.19.247.156/p2p/" & RelayId & "/tcp/60010/p2p-circuit/p2p/" & TargetId
    check parsePeerInfo(address).isErr()

  test "ENRs capabilities are filled when creating RemotePeerInfo":
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    ## When
    var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
    builder.withIpAddressAndPorts(
      ipAddr = Opt.some(parseIpAddress("127.0.0.1")),
      tcpPort = Opt.some(Port(0)),
      udpPort = Opt.some(Port(0)),
    )
    builder.withWakuCapabilities(Capabilities.Relay, Capabilities.Store)

    let recordRes = builder.build()

    ## Then
    assert recordRes.isOk(), $recordRes.error
    let record = recordRes.tryGet()

    let remotePeerInfoRes = record.toRemotePeerInfo()
    assert remotePeerInfoRes.isOk(),
      "failed creating RemotePeerInfo: " & $remotePeerInfoRes.error()

    let remotePeerInfo = remotePeerInfoRes.get()

    check:
      remotePeerInfo.protocols.len == 2
      remotePeerInfo.protocols.contains(WakuRelayCodec)
      remotePeerInfo.protocols.contains(WakuStoreCodec)
