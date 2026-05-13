# Shim to provide valueOr and withValue for Option[T]

{.push raises: [].}

import std/options

template valueOr*[T](self: Option[T], def: untyped): T =
  let s = self
  if s.isSome():
    s.get()
  else:
    def

template withValue*[T](self: Option[T], value, body: untyped) =
  let s = self
  if s.isSome():
    let value {.inject.} = s.get()
    body

template withValue*[T](self: Option[T], value, body, elseStmt: untyped) =
  let s = self
  if s.isSome():
    let value {.inject.} = s.get()
    body
  else:
    elseStmt
