{.used.}

import
  results,
  std/[tempfiles, osproc],
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/peerinfo,
  libp2p/multiaddress,
  libp2p/crypto/crypto
import
  rest/server,
  rest/client,
  rest/responses,
  rest/kernel_api/health/handlers as health_rest_interface,
  rest/kernel_api/health/client as health_rest_client
import
  logos_delivery/waku/[
    common/waku_protocol,
    waku_node,
    node/waku_node as waku_node2,
      # TODO: Remove after moving `git_version` to the app code.
    rln,
    node/health_monitor,
  ],
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../waku_rln_relay/[rln/waku_rln_relay_utils, utils_onchain]

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, Opt.some(extIp), Opt.some(port))

suite "Waku v2 REST API - health":
  # TODO: better test for health
  var anvilProc {.threadVar.}: Process
  var manager {.threadVar.}: RlnEvmGroupManager

  setup:
    anvilProc = runAnvil(stateFile = Opt.some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupRlnEvm(deployContracts = false)

  teardown:
    stopAnvil(anvilProc)

  asyncTest "Get node health info - GET /health":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port # update with bound port for client use

    let healthMonitor = NodeHealthMonitor.new(node)

    installHealthApiHandler(restServer.router, healthMonitor)
    restServer.start()
    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    # kick in rln (currently the only check for health)
    discard await node.mountOnchainRln(
      getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    )

    node.mountLightPushClient()
    await node.mountFilterClient()

    # We don't have a Waku, so we need to set the overall health to READY here in its behalf
    healthMonitor.setOverallHealth(HealthStatus.READY)

    # When
    var response = await client.healthCheck()
    let report = response.data

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      report.nodeHealth == HealthStatus.READY
      report.protocolsHealth.len() == 13

      report.getHealth(RelayProtocol).health == HealthStatus.NOT_READY
      report.getHealth(RelayProtocol).desc == Opt.some("No connected peers")

      report.getHealth(RlnRelayProtocol).health == HealthStatus.READY

      report.getHealth(LightpushProtocol).health == HealthStatus.NOT_MOUNTED
      report.getHealth(LegacyLightpushProtocol).health == HealthStatus.NOT_MOUNTED
      report.getHealth(FilterProtocol).health == HealthStatus.NOT_MOUNTED
      report.getHealth(StoreProtocol).health == HealthStatus.NOT_MOUNTED
      report.getHealth(PeerExchangeProtocol).health == HealthStatus.NOT_MOUNTED
      report.getHealth(RendezvousProtocol).health == HealthStatus.NOT_MOUNTED
      report.getHealth(MixProtocol).health == HealthStatus.NOT_MOUNTED

      report.getHealth(LightpushClientProtocol).health == HealthStatus.NOT_READY
      report.getHealth(LightpushClientProtocol).desc ==
        Opt.some("No Lightpush service peer available yet")

      report.getHealth(LegacyLightpushClientProtocol).health == HealthStatus.NOT_MOUNTED
      report.getHealth(StoreClientProtocol).health == HealthStatus.NOT_MOUNTED

      report.getHealth(FilterClientProtocol).health == HealthStatus.NOT_READY
      report.getHealth(FilterClientProtocol).desc ==
        Opt.some("No Filter service peer available yet")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "RLN member reports READY only once its Merkle proof path is fetched":
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let healthMonitor = NodeHealthMonitor.new(node)
    let rln = await node.mountOnchainRln(
      getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    )

    # Without credentials the node only validates proofs.
    check (await healthMonitor.getProtocolHealthInfo(RlnRelayProtocol)).health ==
      HealthStatus.READY

    let rlnManager = cast[RlnEvmGroupManager](rln.groupManager)
    (await rlnManager.register(generateCredentials(), UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register: " & error

    # A member with no Merkle proof path cannot generate proofs yet.
    check (await healthMonitor.getProtocolHealthInfo(RlnRelayProtocol)).health ==
      HealthStatus.SYNCHRONIZING

    (await rlnManager.ensureFreshMerkleProofPath()).isOkOr:
      assert false, "Failed to fetch Merkle proof path: " & error

    check (await healthMonitor.getProtocolHealthInfo(RlnRelayProtocol)).health ==
      HealthStatus.READY

    await node.stop()
