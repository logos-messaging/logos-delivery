{.push raises: [].}

import results, protobuf_serialization, protobuf_serialization/pkg/results, ../waku_core

type
  PushRequest* {.proto2.} = object
    pubSubTopic* {.fieldNumber: 1, required.}: string
    message* {.fieldNumber: 2, ext, required.}: WakuMessage

  PushResponse* {.proto2.} = object
    isSuccess* {.fieldNumber: 1, required.}: bool
    info* {.fieldNumber: 2.}: Opt[string]

  PushRPC* {.proto2.} = object
    requestId* {.fieldNumber: 1, required.}: string
    request* {.fieldNumber: 2.}: Opt[PushRequest]
    response* {.fieldNumber: 3.}: Opt[PushResponse]
