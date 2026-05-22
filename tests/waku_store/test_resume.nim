{.used.}

import std/[options, net], testutils/unittests, chronos, results

import
  waku/[
    node/peer_manager,
    node/waku_node,
    waku_core,
    waku_store/resume,
    waku_store/common,
    waku_archive/driver,
  ],
  ../testlib/[wakucore, testasync, wakunode],
  ./store_utils,
  ../waku_archive/archive_utils

suite "Store Resume":
  var resume {.threadvar.}: StoreResume

  asyncSetup:
    let resumeRes: Result[StoreResume, string] =
      StoreResume.new(peerManager = nil, wakuArchive = nil, wakuStoreClient = nil)

    assert resumeRes.isOk(), $resumeRes.error

    resume = resumeRes.get()

  asyncTeardown:
    await resume.stopWait()

  asyncTest "get set roundtrip":
    let ts = getNowInNanosecondTime()

    let setRes = resume.setLastOnlineTimestamp(ts)
    assert setRes.isOk(), $setRes.error

    let getRes = resume.getLastOnlineTimestamp()
    assert getRes.isOk(), $getRes.error

    let getTs = getRes.get()

    assert getTs == ts, "wrong timestamp"

suite "Store Resume - End to End":
  var server {.threadvar.}: WakuNode
  var client {.threadvar.}: WakuNode

  var serverDriver {.threadvar.}: ArchiveDriver
  var clientDriver {.threadvar.}: ArchiveDriver

  asyncSetup:
    let messages = @[
      fakeWakuMessage(@[byte 00]),
      fakeWakuMessage(@[byte 01]),
      fakeWakuMessage(@[byte 02]),
      fakeWakuMessage(@[byte 03]),
      fakeWakuMessage(@[byte 04]),
      fakeWakuMessage(@[byte 05]),
      fakeWakuMessage(@[byte 06]),
      fakeWakuMessage(@[byte 07]),
      fakeWakuMessage(@[byte 08]),
      fakeWakuMessage(@[byte 09]),
    ]

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, IPv4_any(), Port(0))
    client = newTestWakuNode(clientKey, IPv4_any(), Port(0))

    serverDriver = newArchiveDriverWithMessages(DefaultPubsubTopic, messages)
    clientDriver = newSqliteArchiveDriver()

    let mountServerArchiveRes = server.mountArchive(serverDriver)
    let mountClientArchiveRes = client.mountArchive(clientDriver)

    assert mountServerArchiveRes.isOk()
    assert mountClientArchiveRes.isOk()

    await server.mountStore()
    await client.mountStore()

    client.mountStoreClient()
    server.mountStoreClient()

    client.setupStoreResume()

    await server.start()

    let serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()

    client.peerManager.addServicePeer(serverRemotePeerInfo, WakuStoreCodec)

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  asyncTest "10 messages resume":
    var countRes = await clientDriver.getMessagesCount()
    assert countRes.isOk(), $countRes.error

    check:
      countRes.get() == 0

    await client.start()

    countRes = await clientDriver.getMessagesCount()
    assert countRes.isOk(), $countRes.error

    check:
      countRes.get() == 10
