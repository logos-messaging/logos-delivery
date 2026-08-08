## Cross-thread allocation helpers backed by libc `malloc`/`free`.
## Avoids Nim `allocShared` whose TLS-owned MemRegion segfaults when freed from a
## thread other than the one that allocated (and may have since exited); libc is process-global.

import system/ansi_c

type SharedSeq*[T] = tuple[data: ptr UncheckedArray[T], len: int]

proc alloc*(str: cstring): cstring =
  ## Fresh null-terminated `c_malloc` copy of `str`; free with `dealloc(cstring)`.
  if str.isNil():
    var ret = cast[cstring](c_malloc(1))
    ret[0] = '\0'
    return ret

  let ret = cast[cstring](c_malloc(csize_t(len(str) + 1)))
  copyMem(ret, str, len(str) + 1)
  return ret

proc alloc*(str: string): cstring =
  var ret = cast[cstring](c_malloc(csize_t(str.len + 1)))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret

proc dealloc*(p: cstring) {.inline.} =
  ## Frees an `alloc(...)` buffer. Nil-safe.
  if not p.isNil():
    c_free(cast[pointer](p))

proc allocBox*(size: int): pointer =
  ## `c_malloc` block for a cross-thread callback box; free with `freeBox`.
  c_malloc(csize_t(size))

proc freeBox*(p: pointer) =
  if not p.isNil():
    c_free(p)

proc allocSharedSeq*[T](s: seq[T]): SharedSeq[T] =
  if s.len == 0:
    return (cast[ptr UncheckedArray[T]](nil), 0)

  let data = c_malloc(csize_t(sizeof(T) * s.len))
  copyMem(data, unsafeAddr s[0], sizeof(T) * s.len)
  return (cast[ptr UncheckedArray[T]](data), s.len)

proc deallocSharedSeq*[T](s: var SharedSeq[T]) =
  if not s.data.isNil():
    c_free(s.data)
  s.len = 0

proc toSeq*[T](s: SharedSeq[T]): seq[T] =
  var ret = newSeq[T]()
  for i in 0 ..< s.len:
    ret.add(s.data[i])
  return ret
