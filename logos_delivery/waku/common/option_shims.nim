# Compatibility shims for std/options.
# libp2p 1.15.2 (and earlier) exposed `valueOr` / `withValue` for std `Option[T]`
# via `libp2p/utility`. libp2p 1.15.3 dropped those overloads (only `Opt[T]` and
# `Result[T, E]` remain), which breaks existing waku code that still uses
# std `Option`. Restore the templates locally so the codebase keeps compiling
# while the upstream API gap is resolved.

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
