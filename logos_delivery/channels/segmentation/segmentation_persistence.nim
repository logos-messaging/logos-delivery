## Persistence backend interface for segmentation reassembly state.
##
## Allows partial reassembly state to survive process restarts.

type
  SegmentationPersistenceKind* {.pure.} = enum
    InMemory
    Sqlite

  SegmentationPersistence* = ref object of RootObj
    kind*: SegmentationPersistenceKind

method put*(self: SegmentationPersistence, key: seq[byte], value: seq[byte]) {.base.} =
  discard

method get*(self: SegmentationPersistence, key: seq[byte]): seq[byte] {.base.} =
  discard

method delete*(self: SegmentationPersistence, key: seq[byte]) {.base.} =
  discard
