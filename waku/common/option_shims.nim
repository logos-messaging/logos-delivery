# Compatibility shims for std/options
# The results library removed valueOr/withValue support for Option[T].
# These templates restore that functionality.

{.push raises: [].}

import std/options

template valueOr*[T](self: Option[T], def: untyped): T =
  let tmp = self
  if tmp.isSome():
    tmp.get()
  else:
    def

template withValue*[T](self: Option[T], value, body: untyped): untyped =
  let tmp = self
  if tmp.isSome():
    let value {.inject.} = tmp.get()
    body

template withValue*[T](self: Option[T], value, body, elseBody: untyped): untyped =
  let tmp = self
  if tmp.isSome():
    let value {.inject.} = tmp.get()
    body
  else:
    elseBody
