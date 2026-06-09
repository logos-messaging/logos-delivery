{.push raises: [].}

import chronos

import ../topics, ../message

type FilterPushHandler* =
  proc(pubsubTopic: PubsubTopic, message: WakuMessage) {.async, gcsafe, closure.}
