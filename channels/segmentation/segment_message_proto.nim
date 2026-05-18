## Wire format for a single segment, per the Reliable Channel API spec.

type SegmentMessageProto* = object
  entireMessageHash*: seq[byte] ## Keccak256(original payload), 32 bytes
  dataSegmentIndex*: uint32 ## zero-indexed sequence number for data segments
  dataSegmentCount*: uint32 ## number of data segments (>= 1)
  payload*: seq[byte] ## segment payload (data or parity shard)
  paritySegmentIndex*: uint32 ## zero-based sequence number for parity segments
  paritySegmentCount*: uint32 ## number of parity segments
  isParity*: bool ## true for parity segments, false (default) for data segments

proc isParityMessage*(self: SegmentMessageProto): bool =
  self.isParity

proc isValid*(self: SegmentMessageProto): bool =
  ## Validates hash length (32 bytes), segment indices and counts.
  discard

proc encode*(self: SegmentMessageProto): seq[byte] =
  discard

proc decode*(T: type SegmentMessageProto, buf: seq[byte]): T =
  discard
