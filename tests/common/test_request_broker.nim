{.used.}

import testutils/unittests
import chronos
import std/strutils

import waku/common/broker/request_broker

## ---------------------------------------------------------------------------
## Async-mode brokers + tests
## ---------------------------------------------------------------------------

RequestBroker:
  type SimpleResponse = object
    value*: string

  proc signatureFetch*(): Future[Result[SimpleResponse, string]] {.async.}

RequestBroker:
  type KeyedResponse = object
    key*: string
    payload*: string

  proc signatureFetchWithKey*(
    key: string, subKey: int
  ): Future[Result[KeyedResponse, string]] {.async.}

RequestBroker:
  type DualResponse = object
    note*: string
    count*: int

  proc signatureNoInput*(): Future[Result[DualResponse, string]] {.async.}
  proc signatureWithInput*(
    suffix: string
  ): Future[Result[DualResponse, string]] {.async.}

RequestBroker(async):
  type ImplicitResponse = ref object
    note*: string

static:
  doAssert typeof(SimpleResponse.request()) is Future[Result[SimpleResponse, string]]

suite "RequestBroker macro (async mode)":
  test "serves zero-argument providers":
    check SimpleResponse
      .setProvider(
        proc(): Future[Result[SimpleResponse, string]] {.async.} =
          ok(SimpleResponse(value: "hi"))
      )
      .isOk()

    let res = waitFor SimpleResponse.request()
    check res.isOk()
    check res.value.value == "hi"

    SimpleResponse.clearProvider()

  test "zero-argument request errors when unset":
    let res = waitFor SimpleResponse.request()
    check res.isErr()
    check res.error.contains("no zero-arg provider")

  test "serves input-based providers":
    var seen: seq[string] = @[]
    check KeyedResponse
      .setProvider(
        proc(
            key: string, subKey: int
        ): Future[Result[KeyedResponse, string]] {.async.} =
          seen.add(key)
          ok(KeyedResponse(key: key, payload: key & "-payload+" & $subKey))
      )
      .isOk()

    let res = waitFor KeyedResponse.request("topic", 1)
    check res.isOk()
    check res.value.key == "topic"
    check res.value.payload == "topic-payload+1"
    check seen == @["topic"]

    KeyedResponse.clearProvider()

  test "catches provider exception":
    check KeyedResponse
      .setProvider(
        proc(
            key: string, subKey: int
        ): Future[Result[KeyedResponse, string]] {.async.} =
          raise newException(ValueError, "simulated failure")
      )
      .isOk()

    let res = waitFor KeyedResponse.request("neglected", 11)
    check res.isErr()
    check res.error.contains("simulated failure")

    KeyedResponse.clearProvider()

  test "input request errors when unset":
    let res = waitFor KeyedResponse.request("foo", 2)
    check res.isErr()
    check res.error.contains("input signature")

  test "supports both provider types simultaneously":
    check DualResponse
      .setProvider(
        proc(): Future[Result[DualResponse, string]] {.async.} =
          ok(DualResponse(note: "base", count: 1))
      )
      .isOk()

    check DualResponse
      .setProvider(
        proc(suffix: string): Future[Result[DualResponse, string]] {.async.} =
          ok(DualResponse(note: "base" & suffix, count: suffix.len))
      )
      .isOk()

    let noInput = waitFor DualResponse.request()
    check noInput.isOk()
    check noInput.value.note == "base"

    let withInput = waitFor DualResponse.request("-extra")
    check withInput.isOk()
    check withInput.value.note == "base-extra"
    check withInput.value.count == 6

    DualResponse.clearProvider()

  test "clearProvider resets both entries":
    check DualResponse
      .setProvider(
        proc(): Future[Result[DualResponse, string]] {.async.} =
          ok(DualResponse(note: "temp", count: 0))
      )
      .isOk()
    DualResponse.clearProvider()

    let res = waitFor DualResponse.request()
    check res.isErr()

  test "implicit zero-argument provider works by default":
    check ImplicitResponse
      .setProvider(
        proc(): Future[Result[ImplicitResponse, string]] {.async.} =
          ok(ImplicitResponse(note: "auto"))
      )
      .isOk()

    let res = waitFor ImplicitResponse.request()
    check res.isOk()

    ImplicitResponse.clearProvider()
    check res.value.note == "auto"

  test "implicit zero-argument request errors when unset":
    let res = waitFor ImplicitResponse.request()
    check res.isErr()
    check res.error.contains("no zero-arg provider")

  test "no provider override":
    check DualResponse
      .setProvider(
        proc(): Future[Result[DualResponse, string]] {.async.} =
          ok(DualResponse(note: "base", count: 1))
      )
      .isOk()

    check DualResponse
      .setProvider(
        proc(suffix: string): Future[Result[DualResponse, string]] {.async.} =
          ok(DualResponse(note: "base" & suffix, count: suffix.len))
      )
      .isOk()

    let overrideProc = proc(): Future[Result[DualResponse, string]] {.async.} =
      ok(DualResponse(note: "something else", count: 1))

    check DualResponse.setProvider(overrideProc).isErr()

    let noInput = waitFor DualResponse.request()
    check noInput.isOk()
    check noInput.value.note == "base"

    let stillResponse = waitFor DualResponse.request(" still works")
    check stillResponse.isOk()
    check stillResponse.value.note.contains("base still works")

    DualResponse.clearProvider()

    let noResponse = waitFor DualResponse.request()
    check noResponse.isErr()
    check noResponse.error.contains("no zero-arg provider")

    let noResponseArg = waitFor DualResponse.request("Should not work")
    check noResponseArg.isErr()
    check noResponseArg.error.contains("no provider")

    check DualResponse.setProvider(overrideProc).isOk()

    let nowSuccWithOverride = waitFor DualResponse.request()
    check nowSuccWithOverride.isOk()
    check nowSuccWithOverride.value.note == "something else"
    check nowSuccWithOverride.value.count == 1

    DualResponse.clearProvider()

  test "supports keyed providers (async, zero-arg)":
    SimpleResponse.clearProvider()

    check SimpleResponse
      .setProvider(
        proc(): Future[Result[SimpleResponse, string]] {.async.} =
          ok(SimpleResponse(value: "default"))
      )
      .isOk()

    check SimpleResponse
      .setProvider(
        BrokerContext(0x11111111'u32),
        proc(): Future[Result[SimpleResponse, string]] {.async.} =
          ok(SimpleResponse(value: "one")),
      )
      .isOk()

    check SimpleResponse
      .setProvider(
        BrokerContext(0x22222222'u32),
        proc(): Future[Result[SimpleResponse, string]] {.async.} =
          ok(SimpleResponse(value: "two")),
      )
      .isOk()

    let defaultRes = waitFor SimpleResponse.request()
    check defaultRes.isOk()
    check defaultRes.value.value == "default"

    let res1 = waitFor SimpleResponse.request(BrokerContext(0x11111111'u32))
    check res1.isOk()
    check res1.value.value == "one"

    let res2 = waitFor SimpleResponse.request(BrokerContext(0x22222222'u32))
    check res2.isOk()
    check res2.value.value == "two"

    let missing = waitFor SimpleResponse.request(BrokerContext(0x33333333'u32))
    check missing.isErr()
    check missing.error.contains("no provider registered for broker context")

    check SimpleResponse
      .setProvider(
        BrokerContext(0x11111111'u32),
        proc(): Future[Result[SimpleResponse, string]] {.async.} =
          ok(SimpleResponse(value: "dup")),
      )
      .isErr()

    SimpleResponse.clearProvider()

  test "supports keyed providers (async, with args)":
    KeyedResponse.clearProvider()

    check KeyedResponse
      .setProvider(
        proc(
            key: string, subKey: int
        ): Future[Result[KeyedResponse, string]] {.async.} =
          ok(KeyedResponse(key: "default-" & key, payload: $subKey))
      )
      .isOk()

    check KeyedResponse
      .setProvider(
        BrokerContext(0xABCDEF01'u32),
        proc(
            key: string, subKey: int
        ): Future[Result[KeyedResponse, string]] {.async.} =
          ok(KeyedResponse(key: "k1-" & key, payload: "p" & $subKey)),
      )
      .isOk()

    check KeyedResponse
      .setProvider(
        BrokerContext(0xABCDEF02'u32),
        proc(
            key: string, subKey: int
        ): Future[Result[KeyedResponse, string]] {.async.} =
          ok(KeyedResponse(key: "k2-" & key, payload: "q" & $subKey)),
      )
      .isOk()

    let d = waitFor KeyedResponse.request("topic", 7)
    check d.isOk()
    check d.value.key == "default-topic"

    let k1 = waitFor KeyedResponse.request(BrokerContext(0xABCDEF01'u32), "topic", 7)
    check k1.isOk()
    check k1.value.key == "k1-topic"
    check k1.value.payload == "p7"

    let k2 = waitFor KeyedResponse.request(BrokerContext(0xABCDEF02'u32), "topic", 7)
    check k2.isOk()
    check k2.value.key == "k2-topic"
    check k2.value.payload == "q7"

    let miss = waitFor KeyedResponse.request(BrokerContext(0xDEADBEEF'u32), "topic", 7)
    check miss.isErr()
    check miss.error.contains("no provider registered for broker context")

    KeyedResponse.clearProvider()

## ---------------------------------------------------------------------------
## Sync-mode brokers + tests
## ---------------------------------------------------------------------------

RequestBroker(sync):
  type SimpleResponseSync = object
    value*: string

  proc signatureFetch*(): Result[SimpleResponseSync, string]

RequestBroker(sync):
  type KeyedResponseSync = object
    key*: string
    payload*: string

  proc signatureFetchWithKey*(
    key: string, subKey: int
  ): Result[KeyedResponseSync, string]

RequestBroker(sync):
  type DualResponseSync = object
    note*: string
    count*: int

  proc signatureNoInput*(): Result[DualResponseSync, string]
  proc signatureWithInput*(suffix: string): Result[DualResponseSync, string]

RequestBroker(sync):
  type ImplicitResponseSync = ref object
    note*: string

static:
  doAssert typeof(SimpleResponseSync.request()) is Result[SimpleResponseSync, string]
  doAssert not (
    typeof(SimpleResponseSync.request()) is Future[Result[SimpleResponseSync, string]]
  )
  doAssert typeof(KeyedResponseSync.request("topic", 1)) is
    Result[KeyedResponseSync, string]

suite "RequestBroker macro (sync mode)":
  test "serves zero-argument providers (sync)":
    check SimpleResponseSync
      .setProvider(
        proc(): Result[SimpleResponseSync, string] =
          ok(SimpleResponseSync(value: "hi"))
      )
      .isOk()

    let res = SimpleResponseSync.request()
    check res.isOk()
    check res.value.value == "hi"

    SimpleResponseSync.clearProvider()

  test "zero-argument request errors when unset (sync)":
    let res = SimpleResponseSync.request()
    check res.isErr()
    check res.error.contains("no zero-arg provider")

  test "serves input-based providers (sync)":
    var seen: seq[string] = @[]
    check KeyedResponseSync
      .setProvider(
        proc(key: string, subKey: int): Result[KeyedResponseSync, string] =
          seen.add(key)
          ok(KeyedResponseSync(key: key, payload: key & "-payload+" & $subKey))
      )
      .isOk()

    let res = KeyedResponseSync.request("topic", 1)
    check res.isOk()
    check res.value.key == "topic"
    check res.value.payload == "topic-payload+1"
    check seen == @["topic"]

    KeyedResponseSync.clearProvider()

  test "catches provider exception (sync)":
    check KeyedResponseSync
      .setProvider(
        proc(key: string, subKey: int): Result[KeyedResponseSync, string] =
          raise newException(ValueError, "simulated failure")
      )
      .isOk()

    let res = KeyedResponseSync.request("neglected", 11)
    check res.isErr()
    check res.error.contains("simulated failure")

    KeyedResponseSync.clearProvider()

  test "input request errors when unset (sync)":
    let res = KeyedResponseSync.request("foo", 2)
    check res.isErr()
    check res.error.contains("input signature")

  test "supports both provider types simultaneously (sync)":
    check DualResponseSync
      .setProvider(
        proc(): Result[DualResponseSync, string] =
          ok(DualResponseSync(note: "base", count: 1))
      )
      .isOk()

    check DualResponseSync
      .setProvider(
        proc(suffix: string): Result[DualResponseSync, string] =
          ok(DualResponseSync(note: "base" & suffix, count: suffix.len))
      )
      .isOk()

    let noInput = DualResponseSync.request()
    check noInput.isOk()
    check noInput.value.note == "base"

    let withInput = DualResponseSync.request("-extra")
    check withInput.isOk()
    check withInput.value.note == "base-extra"
    check withInput.value.count == 6

    DualResponseSync.clearProvider()

  test "clearProvider resets both entries (sync)":
    check DualResponseSync
      .setProvider(
        proc(): Result[DualResponseSync, string] =
          ok(DualResponseSync(note: "temp", count: 0))
      )
      .isOk()
    DualResponseSync.clearProvider()

    let res = DualResponseSync.request()
    check res.isErr()

  test "implicit zero-argument provider works by default (sync)":
    check ImplicitResponseSync
      .setProvider(
        proc(): Result[ImplicitResponseSync, string] =
          ok(ImplicitResponseSync(note: "auto"))
      )
      .isOk()

    let res = ImplicitResponseSync.request()
    check res.isOk()

    ImplicitResponseSync.clearProvider()
    check res.value.note == "auto"

  test "implicit zero-argument request errors when unset (sync)":
    let res = ImplicitResponseSync.request()
    check res.isErr()
    check res.error.contains("no zero-arg provider")

  test "implicit zero-argument provider raises error (sync)":
    check ImplicitResponseSync
      .setProvider(
        proc(): Result[ImplicitResponseSync, string] =
          raise newException(ValueError, "simulated failure")
      )
      .isOk()

    let res = ImplicitResponseSync.request()
    check res.isErr()
    check res.error.contains("simulated failure")

    ImplicitResponseSync.clearProvider()

  test "supports keyed providers (sync, zero-arg)":
    SimpleResponseSync.clearProvider()

    check SimpleResponseSync
      .setProvider(
        proc(): Result[SimpleResponseSync, string] =
          ok(SimpleResponseSync(value: "default"))
      )
      .isOk()

    check SimpleResponseSync
      .setProvider(
        BrokerContext(0x10101010'u32),
        proc(): Result[SimpleResponseSync, string] =
          ok(SimpleResponseSync(value: "ten")),
      )
      .isOk()

    let defaultRes = SimpleResponseSync.request()
    check defaultRes.isOk()
    check defaultRes.value.value == "default"

    let keyedRes = SimpleResponseSync.request(BrokerContext(0x10101010'u32))
    check keyedRes.isOk()
    check keyedRes.value.value == "ten"

    let miss = SimpleResponseSync.request(BrokerContext(0x20202020'u32))
    check miss.isErr()
    check miss.error.contains("no provider registered for broker context")

    SimpleResponseSync.clearProvider()

  test "supports keyed providers (sync, with args)":
    KeyedResponseSync.clearProvider()

    check KeyedResponseSync
      .setProvider(
        proc(key: string, subKey: int): Result[KeyedResponseSync, string] =
          ok(KeyedResponseSync(key: "default-" & key, payload: $subKey))
      )
      .isOk()

    check KeyedResponseSync
      .setProvider(
        BrokerContext(0xA0A0A0A0'u32),
        proc(key: string, subKey: int): Result[KeyedResponseSync, string] =
          ok(KeyedResponseSync(key: "k-" & key, payload: "p" & $subKey)),
      )
      .isOk()

    let d = KeyedResponseSync.request("topic", 2)
    check d.isOk()
    check d.value.key == "default-topic"

    let keyed = KeyedResponseSync.request(BrokerContext(0xA0A0A0A0'u32), "topic", 2)
    check keyed.isOk()
    check keyed.value.key == "k-topic"
    check keyed.value.payload == "p2"

    let miss = KeyedResponseSync.request(BrokerContext(0xB0B0B0B0'u32), "topic", 2)
    check miss.isErr()
    check miss.error.contains("no provider registered for broker context")

    KeyedResponseSync.clearProvider()

## ---------------------------------------------------------------------------
## POD / external type brokers + tests (distinct/alias behavior)
## ---------------------------------------------------------------------------

type ExternalDefinedTypeAsync = object
  label*: string

type ExternalDefinedTypeSync = object
  label*: string

type ExternalDefinedTypeShared = object
  label*: string

RequestBroker:
  type PodResponse = int

  proc signatureFetch*(): Future[Result[PodResponse, string]] {.async.}

RequestBroker:
  type ExternalAliasedResponse = ExternalDefinedTypeAsync

  proc signatureFetch*(): Future[Result[ExternalAliasedResponse, string]] {.async.}

RequestBroker(sync):
  type ExternalAliasedResponseSync = ExternalDefinedTypeSync

  proc signatureFetch*(): Result[ExternalAliasedResponseSync, string]

RequestBroker(sync):
  type DistinctStringResponseA = distinct string

RequestBroker(sync):
  type DistinctStringResponseB = distinct string

RequestBroker(sync):
  type ExternalDistinctResponseA = distinct ExternalDefinedTypeShared

RequestBroker(sync):
  type ExternalDistinctResponseB = distinct ExternalDefinedTypeShared

suite "RequestBroker macro (POD/external types)":
  test "supports non-object response types (async)":
    check PodResponse
      .setProvider(
        proc(): Future[Result[PodResponse, string]] {.async.} =
          ok(PodResponse(123))
      )
      .isOk()

    let res = waitFor PodResponse.request()
    check res.isOk()
    check int(res.value) == 123

    PodResponse.clearProvider()

  test "supports aliased external types (async)":
    check ExternalAliasedResponse
      .setProvider(
        proc(): Future[Result[ExternalAliasedResponse, string]] {.async.} =
          ok(ExternalAliasedResponse(ExternalDefinedTypeAsync(label: "ext")))
      )
      .isOk()

    let res = waitFor ExternalAliasedResponse.request()
    check res.isOk()
    check ExternalDefinedTypeAsync(res.value).label == "ext"

    ExternalAliasedResponse.clearProvider()

  test "supports aliased external types (sync)":
    check ExternalAliasedResponseSync
      .setProvider(
        proc(): Result[ExternalAliasedResponseSync, string] =
          ok(ExternalAliasedResponseSync(ExternalDefinedTypeSync(label: "ext")))
      )
      .isOk()

    let res = ExternalAliasedResponseSync.request()
    check res.isOk()
    check ExternalDefinedTypeSync(res.value).label == "ext"

    ExternalAliasedResponseSync.clearProvider()

  test "distinct response types avoid overload ambiguity (sync)":
    check DistinctStringResponseA
      .setProvider(
        proc(): Result[DistinctStringResponseA, string] =
          ok(DistinctStringResponseA("a"))
      )
      .isOk()

    check DistinctStringResponseB
      .setProvider(
        proc(): Result[DistinctStringResponseB, string] =
          ok(DistinctStringResponseB("b"))
      )
      .isOk()

    check ExternalDistinctResponseA
      .setProvider(
        proc(): Result[ExternalDistinctResponseA, string] =
          ok(ExternalDistinctResponseA(ExternalDefinedTypeShared(label: "ea")))
      )
      .isOk()

    check ExternalDistinctResponseB
      .setProvider(
        proc(): Result[ExternalDistinctResponseB, string] =
          ok(ExternalDistinctResponseB(ExternalDefinedTypeShared(label: "eb")))
      )
      .isOk()

    let resA = DistinctStringResponseA.request()
    let resB = DistinctStringResponseB.request()
    check resA.isOk()
    check resB.isOk()
    check string(resA.value) == "a"
    check string(resB.value) == "b"

    let resEA = ExternalDistinctResponseA.request()
    let resEB = ExternalDistinctResponseB.request()
    check resEA.isOk()
    check resEB.isOk()
    check ExternalDefinedTypeShared(resEA.value).label == "ea"
    check ExternalDefinedTypeShared(resEB.value).label == "eb"

    DistinctStringResponseA.clearProvider()
    DistinctStringResponseB.clearProvider()
    ExternalDistinctResponseA.clearProvider()
    ExternalDistinctResponseB.clearProvider()
