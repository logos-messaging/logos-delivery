{.push raises: [].}

import results, ../waku_core

type LightPushStatusCode* = distinct uint32
proc `==`*(a, b: LightPushStatusCode): bool {.borrow.}
proc `$`*(code: LightPushStatusCode): string {.borrow.}

type
  LightpushRequest* = object
    requestId*: string
    pubSubTopic*: Opt[PubsubTopic]
    message*: WakuMessage

  LightPushResponse* = object
    requestId*: string
    statusCode*: LightPushStatusCode
    statusDesc*: Opt[string]
    relayPeerCount*: Opt[uint32]
