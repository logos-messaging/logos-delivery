{.push raises: [].}

import results, ../common/protobuf, ../waku_core

type
  PushRequest* {.proto3.} = object
    pubSubTopic* {.fieldNumber: 1.}: string
    message* {.fieldNumber: 2.}: WakuMessage

  PushResponse* {.proto3.} = object
    isSuccess* {.fieldNumber: 1.}: bool
    info* {.fieldNumber: 2.}: Opt[string]

  PushRPC* {.proto3.} = object
    requestId* {.fieldNumber: 1.}: string
    request* {.fieldNumber: 2.}: Opt[PushRequest]
    response* {.fieldNumber: 3.}: Opt[PushResponse]
