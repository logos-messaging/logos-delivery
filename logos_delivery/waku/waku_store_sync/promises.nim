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
    peerId: PeerId
    madeAt: Moment
    ids: seq[SyncID]
    numWantedElements: int # elements of the round that are still wanted from it
    anyDelivered: bool # the peer sent at least one element of the round
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

func promise*(
    self: var Promises, peerId: PeerId, ids: seq[SyncID], now: Moment
): seq[SyncID] =
  ## Records the elements that `peerId` promised in one round. Returns the
  ## elements to keep as pending. An element that the same peer already let go
  ## stays in its released round, so that this peer cannot keep the node from
  ## asking another.
  let round = (ref PromiseRound)(peerId: peerId, madeAt: now)
  for id in ids:
    let earlier = self.wanted.getOrDefault(id.hash)
    if not earlier.isNil():
      if earlier.released and earlier.peerId == peerId:
        continue
      earlier.numWantedElements.dec()
    round.ids.add(id)
    round.numWantedElements.inc()
    self.wanted[id.hash] = round

  if round.ids.len > 0:
    self.peers
      .mgetOrPut(peerId, PeerRounds(rounds: initDeque[ref PromiseRound]())).rounds
      .addLast(round)
  return round.ids

func arrive*(
    self: var Promises, hash: WakuMessageHash, sender: Opt[PeerId], now: Moment
): Arrival =
  ## Records the arrival of an element. `sender` is the peer that transferred it,
  ## none for relay and the other sources. Only a delivery by the peer that
  ## promised the element shows that this peer still works through its rounds.
  var round: ref PromiseRound
  if not self.wanted.pop(hash, round):
    return Arrival.Unwanted
  round.numWantedElements.dec()
  if sender.isSome() and sender.get() == round.peerId:
    round.anyDelivered = true
    self.peers.withValue(round.peerId, rounds):
      rounds.lastDelivery = now
  return if round.released: Arrival.Late else: Arrival.Pending

func release(self: var Promises, round: ref PromiseRound, ended: var seq[SyncID]) =
  round.released = true
  self.released.add(round)
  for id in round.ids:
    if self.wanted.getOrDefault(id.hash) == round:
      ended.add(id)

func newestDelivered(rounds: Deque[ref PromiseRound]): int =
  ## The index of the newest round with a delivery, -1 when none has one. A
  ## delivery of a round shows that the peer sent the rounds before it, so the
  ## elements of those rounds that did not arrive are lost.
  var newest = -1
  for i in 0 ..< rounds.len:
    if rounds[i].anyDelivered:
      newest = i
  return newest

func isStale(self: Promises, round: ref PromiseRound, lastDelivery, now: Moment): bool =
  ## True when the peer sent nothing of its promises for one timeout, or when
  ## the round reached `maxPending`.
  now >= max(round.madeAt, lastDelivery) + self.timeout or
    now >= round.madeAt + self.maxPending

func releaseStale(
    self: var Promises, peerRounds: var PeerRounds, now: Moment, ended: var seq[SyncID]
) =
  let newest = peerRounds.rounds.newestDelivered()
  var kept = initDeque[ref PromiseRound]()
  for i in 0 ..< peerRounds.rounds.len:
    let round = peerRounds.rounds[i]
    if round.numWantedElements == 0:
      continue
    if i < newest or self.isStale(round, peerRounds.lastDelivery, now):
      self.release(round, ended)
    else:
      kept.addLast(round)
  peerRounds.rounds = kept

func dropUnwanted(self: var Promises, now: Moment): seq[WakuMessageHash] =
  ## Forgets the released rounds whose accept window ended, and returns their
  ## elements that are no longer wanted.
  var
    kept: seq[ref PromiseRound]
    dropped: seq[WakuMessageHash]
  for round in self.released:
    if round.numWantedElements == 0:
      continue
    if now < round.madeAt + self.acceptWindow:
      kept.add(round)
      continue
    for id in round.ids:
      if self.wanted.getOrDefault(id.hash) == round:
        self.wanted.del(id.hash)
        dropped.add(id.hash)
  self.released = kept
  return dropped

func expire*(
    self: var Promises, now: Moment
): tuple[ended: seq[SyncID], dropped: seq[WakuMessageHash]] =
  ## Releases the rounds that are no longer pending. `ended` holds their elements
  ## that are still wanted, so that the caller removes their placeholders.
  ## `dropped` holds the elements that are no longer wanted.
  var
    ended: seq[SyncID]
    idle: seq[PeerId]
  for peerId, peerRounds in self.peers.mpairs:
    self.releaseStale(peerRounds, now, ended)
    if peerRounds.rounds.len == 0:
      idle.add(peerId)
  for peerId in idle:
    self.peers.del(peerId)

  return (ended, self.dropUnwanted(now))
