import results

type PagingDirection* {.pure.} = enum
  ## PagingDirection determines the direction of pagination
  BACKWARD = uint32(0)
  FORWARD = uint32(1)

proc default*(): PagingDirection {.inline.} =
  PagingDirection.FORWARD

proc into*(b: bool): PagingDirection =
  PagingDirection(b)

proc into*(b: Opt[bool]): PagingDirection =
  if b.isNone():
    return default()
  b.get().into()

proc into*(d: PagingDirection): bool =
  d == PagingDirection.FORWARD

proc into*(d: Opt[PagingDirection]): bool =
  if d.isNone():
    return false
  d.get().into()

proc into*(s: string): PagingDirection =
  (s == "true").into()
