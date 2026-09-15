## The peer manager dial path: its own switch, or a libp2p node another process owns.

{.push raises: [].}

import results, chronicles, chronos, libp2p/[multiaddress, peerid, switch]

logScope:
  topics = "waku net backend"

type
  NetBackend* = ref object of RootObj

  SwitchNetBackend* = ref object of NetBackend
    switch: Switch

method dial*(
    backend: NetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    timeout: Duration,
): Future[Opt[Connection]] {.base, async: (raises: []).} =
  raiseAssert "[NetBackend.dial] abstract method not implemented"

func new*(T: type SwitchNetBackend, switch: Switch): T =
  SwitchNetBackend(switch: switch)

method dial*(
    backend: SwitchNetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    timeout: Duration,
): Future[Opt[Connection]] {.async: (raises: []).} =
  let dialFut = backend.switch.dial(peerId, addrs, proto)

  let res = catch:
    if await dialFut.withTimeout(timeout):
      return Opt.some(dialFut.read())

  if not dialFut.finished():
    await noCancel cancelAndWait(dialFut)

  let reasonFailed = if res.isOk(): "timed out" else: res.error.msg

  trace "Dialing peer failed", peerId = peerId, reason = reasonFailed, proto = proto

  return Opt.none(Connection)

{.pop.}
