{.used.}

import std/options, results, testutils/unittests
import logos_delivery/waku/waku_core/topics

suite "Waku Message - Content topics namespacing":
  test "Stringify namespaced content topic":
    ## Given
    var ns = NsContentTopic()
    ns.generation = none(int)
    ns.application = "toychat"
    ns.version = "2"
    ns.name = "huilong"
    ns.encoding = "proto"

    ## When
    let topic = $ns

    ## Then
    check:
      topic == "/toychat/2/huilong/proto"

  test "Parse content topic string - Valid string":
    ## Given
    let topic = "/toychat/2/huilong/proto"

    ## When
    let nsRes = NsContentTopic.parse(topic)

    ## Then
    assert nsRes.isOk(), $nsRes.error

    let ns = nsRes.get()
    check:
      ns.generation == none(int)
      ns.application == "toychat"
      ns.version == "2"
      ns.name == "huilong"
      ns.encoding == "proto"

  test "Parse content topic string - Valid string with sharding":
    ## Given
    let topic = "/0/toychat/2/huilong/proto"

    ## When
    let nsRes = NsContentTopic.parse(topic)

    ## Then
    assert nsRes.isOk(), $nsRes.error

    let ns = nsRes.get()
    check:
      ns.generation == some(0)
      ns.application == "toychat"
      ns.version == "2"
      ns.name == "huilong"
      ns.encoding == "proto"

  test "Parse content topic string - Invalid string: missing leading slash":
    ## Given
    let topic = "toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic)

    ## Then
    assert ns.isErr(), $ns.get()

    let err = ns.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat
      err.cause == "content-topic '" & topic & "' must start with slash"

  test "Parse content topic string - Invalid string: not namespaced":
    ## Given
    let topic = "/this-is-not-namespaced"

    ## When
    let ns = NsContentTopic.parse(topic)

    ## Then
    assert ns.isErr(), $ns.get()

    let err = ns.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat
      err.cause ==
        "Invalid content topic structure. Expected either /<application>/<version>/<topic-name>/<encoding> or /<gen>/<application>/<version>/<topic-name>/<encoding>"

  test "Parse content topic string - Invalid string: missing encoding part":
    ## Given
    let topic = "/toychat/2/huilong"

    ## When
    let ns = NsContentTopic.parse(topic)

    ## Then
    assert ns.isErr(), $ns.get()

    let err = ns.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat
      err.cause ==
        "Invalid content topic structure. Expected either /<application>/<version>/<topic-name>/<encoding> or /<gen>/<application>/<version>/<topic-name>/<encoding>"

  test "Parse content topic string - Invalid string: wrong extra parts":
    ## Given
    let topic = "/toychat/2/huilong/proto/33"

    ## When
    let ns = NsContentTopic.parse(topic)

    ## Then
    assert ns.isErr(), $ns.get()

    let err = ns.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat
      err.cause == "generation should be a numeric value"

  test "Parse content topic string - Invalid string: non numeric generation":
    ## Given
    let topic = "/first/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic)

    ## Then
    assert ns.isErr(), $ns.get()

    let err = ns.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat
      err.cause == "generation should be a numeric value"

suite "Waku Message - Pub-sub topics namespacing":
  test "Stringify static sharding pub-sub topic":
    ## Given
    var shard = RelayShard(clusterId: 0, shardId: 2)

    ## When
    let topic = $shard

    ## Then
    check:
      topic == "/waku/2/rs/0/2"

  test "Parse invalid pub-sub topic string":
    ## Given
    let topic = "/waku/2/waku-dev"

    ## When
    let shardRes = RelayShard.parse(topic)

    ## Then
    check shardRes.isErr()
    let err = shardRes.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat

  test "Parse static sharding pub-sub topic string - Valid string":
    ## Given
    let topic = "/waku/2/rs/16/42"

    ## When
    let shardRes = RelayShard.parse(topic)

    ## Then
    check shardRes.isOk()

    let shard = shardRes.get()
    check:
      shard.clusterId == 16
      shard.shardId == 42

  test "Parse pub-sub topic string - Invalid string: invalid protocol version":
    ## Given
    let topic = "/waku/1/rs/16/42"

    ## When
    let shard = RelayShard.parse(topic)

    ## Then
    check shard.isErr()
    let err = shard.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat

  test "Parse static sharding pub-sub topic string - Invalid string: empty cluster id value":
    ## Given
    let topic = "/waku/2/rs//02"

    ## When
    let shard = RelayShard.parse(topic)

    ## Then
    check shard.isErr()
    let err = shard.tryError()
    check:
      err.kind == ParsingErrorKind.MissingPart
      err.part == "cluster_id"

  test "Parse static sharding pub-sub topic string - Invalid string: cluster id value":
    ## Given
    let topic = "/waku/2/rs/xx/77"

    ## When
    let shard = RelayShard.parse(topic)

    ## Then
    check shard.isErr()
    let err = shard.tryError()
    check:
      err.kind == ParsingErrorKind.InvalidFormat
