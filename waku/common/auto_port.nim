{.push raises: [].}

import std/random

const AutoPortRetryCount* = 20

var
  autoPortMin* = 50000'u16
  autoPortMax* = 59000'u16
  rng = initRand()

proc getAutoPort*(): uint16 =
  uint16(rng.rand(autoPortMin.int .. autoPortMax.int))
