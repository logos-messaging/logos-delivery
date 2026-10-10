{.push raises: [].}

import std/net

type RestServerConf* = object
  allowOrigin*: seq[string]
  listenAddress*: IpAddress
  port*: Port
  admin*: bool
  relayCacheCapacity*: uint32
  messagingCacheCapacity*: uint32
    ## Received messages the messaging REST API keeps between polls.
