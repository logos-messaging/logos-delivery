{.push raises: [].}

import results, ../waku_core

type
  PushRequest* = object
    pubSubTopic*: string
    message*: WakuMessage

  PushResponse* = object
    isSuccess*: bool
    info*: Opt[string]

  PushRPC* = object
    requestId*: string
    request*: Opt[PushRequest]
    response*: Opt[PushResponse]
