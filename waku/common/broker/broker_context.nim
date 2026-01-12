{.push raises: [].}

import std/[strutils, concurrency/atomics], chronos

type BrokerContext* = distinct uint32

func `==`*(a, b: BrokerContext): bool =
  uint32(a) == uint32(b)

func `!=`*(a, b: BrokerContext): bool =
  uint32(a) != uint32(b)

func `$`*(bc: BrokerContext): string =
  toHex(uint32(bc), 8)

const DefaultBrokerContext* = BrokerContext(0xCAFFE14E'u32)

# Global broker context accessor.
#
# NOTE: This intentionally creates a *single* active BrokerContext per process
# (per event loop thread). Use only if you accept serialization of all broker
# context usage through the lock.
var globalBrokerContextLock {.threadvar.}: AsyncLock
globalBrokerContextLock = newAsyncLock()
var globalBrokerContextValue {.threadvar.}: BrokerContext
globalBrokerContextValue = DefaultBrokerContext
proc globalBrokerContext*(): BrokerContext =
  ## Returns the currently active global broker context.
  ##
  ## This is intentionally lock-free; callers should use it inside
  ## `withNewGlobalBrokerContext` / `withGlobalBrokerContext`.
  globalBrokerContextValue

var gContextCounter: Atomic[uint32]

proc NewBrokerContext*(): BrokerContext =
  var nextId = gContextCounter.fetchAdd(1, moRelaxed)
  if nextId == uint32(DefaultBrokerContext):
    nextId = gContextCounter.fetchAdd(1, moRelaxed)
  return BrokerContext(nextId)

template lockGlobalBrokerContext*(brokerCtx: BrokerContext, body: untyped): untyped =
  ## Runs `body` while holding the global broker context lock with the provided
  ## `brokerCtx` installed as the globally accessible context.
  ##
  ## This template is intended for use from within `chronos` async procs.
  block:
    await noCancel(globalBrokerContextLock.acquire())
    let previousBrokerCtx = globalBrokerContextValue
    globalBrokerContextValue = brokerCtx
    try:
      body
    finally:
      globalBrokerContextValue = previousBrokerCtx
      try:
        globalBrokerContextLock.release()
      except AsyncLockError:
        doAssert false, "globalBrokerContextLock.release(): lock not held"

template lockNewGlobalBrokerContext*(body: untyped): untyped =
  ## Runs `body` while holding the global broker context lock with a freshly
  ## generated broker context installed as the global accessor.
  ##
  ## The previous global broker context (if any) is restored on exit.
  lockGlobalBrokerContext(NewBrokerContext()):
    body

{.pop.}
