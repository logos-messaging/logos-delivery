import std/[strutils, concurrency/atomics]

type BrokerContext* = distinct uint32

func `==`*(a, b: BrokerContext): bool {.borrow.}

func `$`*(bc: BrokerContext): string =
  toHex(uint32(bc), 8)

const DefaultBrokerContext* = BrokerContext(0xCAFFE14E'u32)

var gContextCounter: Atomic[uint32]

proc NewBrokerContext*(): BrokerContext =
  var nextId = gContextCounter.fetchAdd(1, moRelaxed)
  if nextId == uint32(DefaultBrokerContext):
    nextId = gContextCounter.fetchAdd(1, moRelaxed)
  return BrokerContext(nextId)
