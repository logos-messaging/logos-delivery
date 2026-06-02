## Polyfill: `valueOr` / `withValue` templates for `std/options.Option[T]`.
##
## Previously provided transitively by `libp2p/utility`, removed in
## nim-libp2p PR #2162 (commit 8a9943145). logos-delivery uses these
## templates pervasively on `Option[T]`. The shim restores them here while
## we adapt to upstream churn; collocated under `waku/compat/` so the
## category is explicit (compatibility with upstream API drift), not a
## generic dumping ground.

{.push raises: [].}

import std/[macros, options]

template valueOr*[T](self: Option[T], body: untyped): untyped =
  let temp = (self)
  if temp.isSome:
    temp.get()
  else:
    body

template withValue*[T](self: Option[T], value, body: untyped): untyped =
  let temp = (self)
  if temp.isSome:
    let `value` {.inject.} = temp.get()
    body

macro withValue*[T](self: Option[T], value, body, elseStmt: untyped): untyped =
  let elseBody = elseStmt[0]
  quote:
    let temp = (`self`)
    if temp.isSome:
      let `value` {.inject.} = temp.get()
      `body`
    else:
      `elseBody`
