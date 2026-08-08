## Memory helpers for the macro-generated `*_CWire` types — the flat C-ABI mirror
## of a Nim object, where strings and seq/Option payloads live in separate buffers
## the struct only points at. These procs allocate and free those buffers, and copy
## the struct across the hop to the FFI thread.

import ../alloc

proc cwireAllocBuf*(size: int): pointer =
  ## Buffer for a wire seq/Option payload. libc `malloc` rather than `allocShared`
  ## so one thread can allocate and a different thread can free (see ../alloc).
  alloc.allocBox(size)

proc cwireFreeBuf*(p: pointer) =
  ## Frees a `cwireAllocBuf` buffer; does nothing if `p` is nil.
  alloc.freeBox(p)

proc cwireAllocStr*(s: string): cstring {.inline.} =
  ## NUL-terminated copy of `s` for a wire string field; free with `cwireFreeStr`.
  alloc.alloc(s)

proc cwireFreeStr*(s: var cstring) {.inline.} =
  ## Frees a wire string field and nils it, so freeing twice is harmless.
  if s.isNil():
    return
  alloc.dealloc(s)
  s = nil

func cwireStructBytes*[W](wire: W): seq[byte] =
  ## The struct's raw bytes, to hand a reply back over the FFI-thread hop. Copies
  ## the pointers, not what they point at, so `wire`'s buffers must stay alive
  ## until the receiver `cwireFree`s them.
  var b = newSeq[byte](sizeof(W))
  copyMem(addr b[0], unsafeAddr wire, sizeof(W))
  b

proc cwireOwnedCopy*[W](wire: W): ptr W =
  ## The same shallow copy, into `malloc` memory the FFI thread adopts and frees;
  ## nil if the allocation fails. `copyMem` because assigning into raw `malloc`
  ## bytes would run ORC's copy hooks over uninitialised memory.
  let p = cast[ptr W](alloc.allocBox(sizeof(W)))
  if p.isNil():
    return nil
  copyMem(p, unsafeAddr wire, sizeof(W))
  return p
