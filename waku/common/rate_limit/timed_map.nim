## TimedMap
## ===========
## Inspired by nim-libp2p's TimedCache class. This is using the same approach to prune
## untouched items from the map where the set timeout duration is reached.
## But unlike TimedCache this TimedMap is capable to hold and return any type of value for a key.
##
## - `mgetOrPut` proc is similar to std/tables, but will renew the timeout for the key.
## - For non-renewal check use `contains` proc.
## - `expire` proc will remove all items that have expired.
##
## Choose your initial timeout for your needs to control the size of the map.

{.push raises: [].}

import std/[hashes, sets]
import chronos/timer, results
import libp2p/utility

export results

type
  TimedEntry[K, V] = ref object of RootObj
    key: K
    value: V
    addedAt: Moment
    expiresAt: Moment
    next, prev: TimedEntry[K, V]

  TimedMap*[K, V] = object of RootObj
    head, tail: TimedEntry[K, V] # nim linked list doesn't allow inserting at pos
    entries: HashSet[TimedEntry[K, V]]
    timeout: Duration

func `==`*[K, V](a, b: TimedEntry[K, V]): bool =
  if isNil(a) == isNil(b):
    isNil(a) or a.key == b.key
  else:
    false

func hash*(a: TimedEntry): Hash =
  if isNil(a):
    default(Hash)
  else:
    hash(a[].key)

func `$`*[T](a: T): string =
  if isNil(a):
    "nil"

  return $a

func `$`*[K, V](a: TimedEntry[K, V]): string =
  if isNil(a):
    return "nil"

  return
    "TimedEntry: key:" & $a.key & ", val:" & $a.value & ", addedAt:" & $a.addedAt &
    ", expiresAt:" & $a.expiresAt

func expire*(t: var TimedMap, now: Moment = Moment.now()) =
  while t.head != nil and t.head.expiresAt <= now:
    t.entries.excl(t.head)
    t.head.prev = nil
    t.head = t.head.next
    if t.head == nil:
      t.tail = nil

func del[K, V](t: var TimedMap[K, V], key: K): Opt[TimedEntry[K, V]] =
  # Removes existing key from cache, returning the previous item if present
  let tmp = TimedEntry[K, V](key: key)
  if tmp in t.entries:
    let item =
      try:
        t.entries[tmp] # use the shared instance in the set
      except KeyError:
        raiseAssert "just checked"
    t.entries.excl(item)

    if t.head == item:
      t.head = item.next
    if t.tail == item:
      t.tail = item.prev

    if item.next != nil:
      item.next.prev = item.prev
    if item.prev != nil:
      item.prev.next = item.next
    Opt.some(item)
  else:
    Opt.none(TimedEntry[K, V])

func remove*[K, V](t: var TimedMap[K, V], key: K): Opt[V] =
  # Removes existing key from cache, returning the previous value if present
  # public version of del without exporting TimedEntry
  let deleted = t.del(key)
  if deleted.isSome():
    Opt.some(deleted[].value)
  else:
    Opt.none(V)

proc mgetOrPut*[K, V](t: var TimedMap[K, V], k: K, v: V, now = Moment.now()): var V =
  # Puts k in cache, returning true if the item was already present and false
  # otherwise. If the item was already present, its expiry timer will be
  # refreshed.
  t.expire(now)

  let
    previous = t.del(k) # Refresh existing item
    addedAt = if previous.isSome(): previous[].addedAt else: now
    value = if previous.isSome(): previous[].value else: v

  let node =
    TimedEntry[K, V](key: k, value: value, addedAt: addedAt, expiresAt: now + t.timeout)
  if t.head == nil:
    t.tail = node
    t.head = t.tail
  else:
    # search from tail because typically that's where we add when now grows
    var cur = t.tail
    while cur != nil and node.expiresAt < cur.expiresAt:
      cur = cur.prev

    if cur == nil:
      node.next = t.head
      t.head.prev = node
      t.head = node
    else:
      node.prev = cur
      node.next = cur.next
      cur.next = node
      if cur == t.tail:
        t.tail = node

  t.entries.incl(node)

  return node.value

func contains*[K, V](t: TimedMap[K, V], k: K): bool =
  let tmp = TimedEntry[K, V](key: k)
  tmp in t.entries

func addedAt*[K, V](t: var TimedMap[K, V], k: K): Moment =
  let tmp = TimedEntry[K, V](key: k)
  try:
    if tmp in t.entries: # raising is slow
      # Use shared instance from entries
      return t.entries[tmp][].addedAt
  except KeyError:
    raiseAssert "just checked"

  default(Moment)

func init*[K, V](T: type TimedMap[K, V], timeout: Duration): T =
  T(timeout: timeout)
