{.push raises: [].}

## The elements that peers promised to this node in reconciliation rounds.
##
## A peer sends its pushes in the order of the rounds that promised them, so a
## promised element is pending, and no round asks another peer for it, while its
## peer still delivers this round or an earlier one. A delivery of a later round
## ends the rounds before it, also for an element that waited at the peer for its
## own copy to arrive. That element is then asked of any peer, and its late push
## is still archived, since an element stays wanted for `acceptWindow`.

import std/[deques, tables], chronos, libp2p/peerid
import ../waku_core/message/digest, ./common

type
  PromiseRound = object
    peer: PeerId
    madeAt: Moment
    ids: seq[SyncID]
    open: int # elements of the round that are still wanted from it
    delivered: bool # the peer sent at least one element of the round
    released: bool # the elements of the round are no longer pending

  PeerRounds = object
    rounds: Deque[ref PromiseRound] # pending rounds, in the order of the pushes
    lastDelivery: Moment

  Promises* = object
    timeout: Duration
    maxPending: Duration
    acceptWindow: Duration
    wanted: Table[WakuMessageHash, ref PromiseRound]
    peers: Table[PeerId, PeerRounds]
    released: seq[ref PromiseRound] # until their accept window ends

  Arrival* {.pure.} = enum
    Unwanted
    Pending # the caller replaces the placeholder of the element
    Late # the round of the element was released, so it has no placeholder

func init*(T: type Promises, timeout, maxPending, acceptWindow: Duration): T =
  ## `timeout`: how long a peer can send nothing of its promises before its
  ## rounds stop being pending. `maxPending`: the longest that a promised element
  ## is pending. `acceptWindow`: how long a promised element is wanted.
  Promises(timeout: timeout, maxPending: maxPending, acceptWindow: acceptWindow)

func isPending*(self: Promises, hash: WakuMessageHash): bool =
  ## True when a peer promised the element and the node waits for that peer.
  let round = self.wanted.getOrDefault(hash)
  not round.isNil() and not round.released

func isWanted*(self: Promises, hash: WakuMessageHash): bool =
  ## True when a round asked for the element and it did not arrive.
  self.wanted.contains(hash)

proc promise*(
    self: var Promises, peer: PeerId, ids: seq[SyncID], now: Moment
): seq[SyncID] =
  ## Records the elements that `peer` promised in one round. Returns the elements
  ## to keep as pending. An element that the same peer already let go stays in its
  ## released round, so that this peer cannot keep the node from asking another.
  let round = (ref PromiseRound)(peer: peer, madeAt: now)
  for id in ids:
    let earlier = self.wanted.getOrDefault(id.hash)
    if not earlier.isNil():
      if earlier.released and earlier.peer == peer:
        continue
      earlier.open.dec()
    round.ids.add(id)
    round.open.inc()
    self.wanted[id.hash] = round

  if round.ids.len > 0:
    self.peers
      .mgetOrPut(peer, PeerRounds(rounds: initDeque[ref PromiseRound]())).rounds
      .addLast(round)
  return round.ids

proc arrive*(
    self: var Promises, hash: WakuMessageHash, sender: Opt[PeerId], now: Moment
): Arrival =
  ## Records the arrival of an element. `sender` is the peer that transferred it,
  ## none for relay and the other sources. Only a delivery by the peer that
  ## promised the element shows that this peer still works through its rounds.
  var round: ref PromiseRound
  if not self.wanted.pop(hash, round):
    return Arrival.Unwanted
  round.open.dec()
  if sender.isSome() and sender.get() == round.peer:
    round.delivered = true
    self.peers.withValue(round.peer, rounds):
      rounds.lastDelivery = now
  return if round.released: Arrival.Late else: Arrival.Pending

proc release(self: var Promises, round: ref PromiseRound, ended: var seq[SyncID]) =
  round.released = true
  self.released.add(round)
  for id in round.ids:
    if self.wanted.getOrDefault(id.hash) == round:
      ended.add(id)

proc expire*(
    self: var Promises, now: Moment
): tuple[ended: seq[SyncID], dropped: seq[WakuMessageHash]] =
  ## Releases the rounds that are no longer pending. `ended` holds their elements
  ## that are still wanted, so that the caller removes their placeholders.
  ## `dropped` holds the elements that are no longer wanted.
  var
    ended: seq[SyncID]
    dropped: seq[WakuMessageHash]
    idle: seq[PeerId]
  for peer, peerRounds in self.peers.mpairs:
    # A delivery of a round shows that the peer sent the rounds before it, so the
    # elements of those rounds that did not arrive are lost.
    var newestDelivered = -1
    for i in 0 ..< peerRounds.rounds.len:
      if peerRounds.rounds[i].delivered:
        newestDelivered = i

    var kept = initDeque[ref PromiseRound]()
    for i in 0 ..< peerRounds.rounds.len:
      let round = peerRounds.rounds[i]
      if round.open == 0:
        continue
      let
        stalled = now >= max(round.madeAt, peerRounds.lastDelivery) + self.timeout
        tooLong = now >= round.madeAt + self.maxPending
      if i < newestDelivered or stalled or tooLong:
        self.release(round, ended)
      else:
        kept.addLast(round)
    peerRounds.rounds = kept
    if kept.len == 0:
      idle.add(peer)
  for peer in idle:
    self.peers.del(peer)

  var kept: seq[ref PromiseRound]
  for round in self.released:
    if round.open == 0:
      continue
    if now < round.madeAt + self.acceptWindow:
      kept.add(round)
      continue
    for id in round.ids:
      if self.wanted.getOrDefault(id.hash) == round:
        self.wanted.del(id.hash)
        dropped.add(id.hash)
  self.released = kept

  return (ended, dropped)
