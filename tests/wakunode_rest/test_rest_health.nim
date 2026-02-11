{.used.}

import
  std/[tempfiles, osproc],
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/peerinfo,
  libp2p/multiaddress,
  libp2p/crypto/crypto
import
  waku/[
    waku_node,
    node/waku_node as waku_node2,
      # TODO: Remove after moving `git_version` to the app code.
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/health/handlers as health_rest_interface,
    rest_api/endpoint/health/client as health_rest_client,
    waku_rln_relay,
    node/health_monitor,
  ],
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../waku_rln_relay/[rln/waku_rln_relay_utils, utils_onchain]

proc testWakuNode(): WakuNode =
  let
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

suite "Waku v2 REST API - health":
  # TODO: better test for health
  var anvilProc {.threadVar.}: Process
  var manager {.threadVar.}: OnchainGroupManager

  setup:
    anvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

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
    await node.mountRlnRelay(
      getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    )

    node.mountLightPushClient()
    await node.mountFilterClient()

    # We don't have a Waku, so we need to set the overall health to READY here in its behalf
    healthMonitor.setOverallHealth(HealthStatus.READY)

    # When
    var response = await client.healthCheck()

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.nodeHealth == HealthStatus.READY
      response.data.protocolsHealth.len() == 15
      response.data.protocolsHealth[0].protocol == "Relay"
      response.data.protocolsHealth[0].health == HealthStatus.NOT_READY
      response.data.protocolsHealth[0].desc == some("No connected peers")
      response.data.protocolsHealth[1].protocol == "Rln Relay"
      response.data.protocolsHealth[1].health == HealthStatus.READY
      response.data.protocolsHealth[2].protocol == "Lightpush"
      response.data.protocolsHealth[2].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[3].protocol == "Legacy Lightpush"
      response.data.protocolsHealth[3].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[4].protocol == "Filter"
      response.data.protocolsHealth[4].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[5].protocol == "Store"
      response.data.protocolsHealth[5].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[6].protocol == "Legacy Store"
      response.data.protocolsHealth[6].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[7].protocol == "Peer Exchange"
      response.data.protocolsHealth[7].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[8].protocol == "Rendezvous"
      response.data.protocolsHealth[8].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[9].protocol == "Mix"
      response.data.protocolsHealth[9].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[10].protocol == "Lightpush Client"
      response.data.protocolsHealth[10].health == HealthStatus.NOT_READY
      response.data.protocolsHealth[10].desc ==
        some("No Lightpush service peer available yet")
      response.data.protocolsHealth[11].protocol == "Legacy Lightpush Client"
      response.data.protocolsHealth[11].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[12].protocol == "Store Client"
      response.data.protocolsHealth[12].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[13].protocol == "Legacy Store Client"
      response.data.protocolsHealth[13].health == HealthStatus.NOT_MOUNTED
      response.data.protocolsHealth[14].protocol == "Filter Client"
      response.data.protocolsHealth[14].health == HealthStatus.NOT_READY
      response.data.protocolsHealth[14].desc ==
        some("No Filter service peer available yet")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
