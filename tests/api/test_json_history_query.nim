{.used.}

import std/json, results, testutils/unittests
import logos_delivery/api/types, library/[json_history_query, utils]

const Topic = "/history-query/1/chat/proto"

suite "History query JSON":
  test "the parser reads each field and refuses a bad query":
    let full =
      parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": 100, "endTime": "200"})
    check full.get() ==
      HistoryQuery.init(ContentTopic(Topic), 100, Opt.some(Timestamp(200)))
    let noEnd = parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": "100"})
    check noEnd.get() == HistoryQuery.init(ContentTopic(Topic), 100)
    let nullEnd =
      parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": 100, "endTime": nil})
    check nullEnd.get() == HistoryQuery.init(ContentTopic(Topic), 100)
    # `getProtoInt64` gives no value for a null, as for a missing key, for each caller.
    let fields = parseJson("""{"empty": null, "five": 5}""")
    check:
      fields.getProtoInt64("empty").get().isNone()
      fields.getProtoInt64("missing").get().isNone()
      fields.getProtoInt64("five").get() == Opt.some(5'i64)
    check:
      parseHistoryQuery("not json").isErr()
      parseHistoryQuery("[]").isErr()
      parseHistoryQuery($ %*{"startTime": 100}).isErr()
      parseHistoryQuery($ %*{"contentTopic": 7, "startTime": 100}).isErr()
      parseHistoryQuery($ %*{"contentTopic": Topic}).isErr()
      parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": "soon"}).isErr()
      parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": 1.5}).isErr()
      parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": true}).isErr()
      parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": 1, "endTime": 1.5})
        .isErr()
      parseHistoryQuery($ %*{"contentTopic": Topic, "startTime": 1, "endTime": "x"})
        .isErr()
