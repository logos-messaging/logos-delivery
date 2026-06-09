{.push raises: [].}

import ../../../waku_core

type Index* = object
  ## This type contains the  description of an Index used in the pagination of WakuMessages
  time*: Timestamp # the time at which the message is generated
  hash*: WakuMessageHash
  pubsubTopic*: PubsubTopic

proc `==`*(x, y: Index): bool =
  return x.hash == y.hash

proc cmp*(x, y: Index): int =
  ## compares x and y
  ## returns 0 if they are equal
  ## returns -1 if x < y
  ## returns 1 if x > y
  ##
  ## Default sorting order priority is:
  ## 1. time
  ## 2. hash

  let timeCMP = cmp(x.time, y.time)
  if timeCMP != 0:
    return timeCMP

  return cmp(x.hash, y.hash)
