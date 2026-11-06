{.used.}

## The C ABI of the libp2p module: installing a plugin, requests answered through
## `logosdelivery_libp2p_response`, events through `logosdelivery_libp2p_event`,
## and the startup check that `libp2pImpl` and the installed module agree.

import std/strutils, results, testutils/unittests, chronos, chronicles, metrics

import
  logos_delivery/waku/factory/[node_factory, waku_conf],
  logos_delivery/waku/libp2p_backend/module_transport,
  logos_delivery/waku/libp2p_iface/module_contract,
  ../testlib/[testasync, wakunode]

var gSeenMethod {.threadvar.}: string

proc echoCall(
    reqId: uint64,
    meth: cstring,
    request: ptr UncheckedArray[byte],
    requestLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## A module that answers synchronously: the peer id of the reply is the method.
  gSeenMethod = $meth
  if $meth == "fail":
    let msg = "boom"
    discard logosdelivery_libp2p_response(
      reqId, 1, cast[ptr UncheckedArray[byte]](unsafeAddr msg[0]), csize_t(msg.len)
    )
    return
  let reply = cborEncode(PeerIdRes(peerId: "echo:" & $meth))
  discard logosdelivery_libp2p_response(
    reqId, 0, cast[ptr UncheckedArray[byte]](unsafeAddr reply[0]), csize_t(reply.len)
  )

suite "libp2p module plugin":
  teardown:
    discard logosdelivery_libp2p_set_module(nil, nil)

  proc install(name: string, abiVersion = Libp2pModuleAbiVersion): cint =
    var plugin =
      Libp2pModulePlugin(abiVersion: abiVersion, name: name.cstring, call: echoCall)
    return logosdelivery_libp2p_set_module(addr plugin, nil)

  test "installing records the module name, clearing removes it":
    check not libp2pModuleInstalled()
    check install("my-libp2p") == 0
    check:
      libp2pModuleInstalled()
      libp2pModuleName() == "my-libp2p"
    discard logosdelivery_libp2p_set_module(nil, nil)
    check not libp2pModuleInstalled()

  test "an ABI version mismatch is refused":
    check install("my-libp2p", abiVersion = Libp2pModuleAbiVersion + 1) == 2
    check not libp2pModuleInstalled()

  asyncTest "a request returns the typed reply, a module error comes back as an error":
    check install("my-libp2p") == 0
    let transport = ModuleTransport.installed().tryGet()

    let reply = await transport.call(ReqPubSubSelfPeerId, Empty(), PeerIdRes)
    check:
      reply.isOk()
      reply.get().peerId == "echo:" & ReqPubSubSelfPeerId
      gSeenMethod == ReqPubSubSelfPeerId

    let failed = await transport.call("fail", Empty(), Empty)
    check:
      failed.isErr()
      "boom" in failed.error

    await transport.close()

  asyncTest "an event reaches the handler registered for it on the node thread":
    check install("my-libp2p") == 0
    let transport = ModuleTransport.installed().tryGet()

    var received = newFuture[seq[byte]]()
    transport.subscribe(
      EvPubSubMessage,
      proc(payload: seq[byte]) {.gcsafe, raises: [].} =
        received.complete(payload),
    )

    let payload = cborEncode(PubSubMessageEv(topic: "t", data: @[1'u8, 2, 3]))
    check logosdelivery_libp2p_event(
      EvPubSubMessage.cstring,
      cast[ptr UncheckedArray[byte]](unsafeAddr payload[0]),
      csize_t(payload.len),
    ) == 0

    check await received.withTimeout(5.seconds)
    let ev = cborDecode(received.read(), PubSubMessageEv).tryGet()
    check:
      ev.topic == "t"
      ev.data == @[1'u8, 2, 3]

    await transport.close()

  test "libp2pImpl and the installed module must agree":
    let conf = defaultTestWakuConf()
    check:
      conf.libp2pImpl == Libp2pImplBuiltin
      checkLibp2pImpl(conf).isOk()
    check install("my-libp2p") == 0

    # a module is installed but the configuration says builtin
    check checkLibp2pImpl(conf).isErr()

    # the names must match; a matching module is not supported by the node yet
    let wrongName = defaultTestWakuConf()
    wrongName.libp2pImpl = "other"
    check "installed libp2p module is 'my-libp2p'" in checkLibp2pImpl(wrongName).error
    let matching = defaultTestWakuConf()
    matching.libp2pImpl = "my-libp2p"
    check "not supported by the node yet" in checkLibp2pImpl(matching).error

    # a module is named but none is installed
    discard logosdelivery_libp2p_set_module(nil, nil)
    check "no libp2p module is installed" in checkLibp2pImpl(matching).error
