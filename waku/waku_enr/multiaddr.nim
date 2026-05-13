{.push raises: [].}

import
  std/[options, sequtils, net],
  stew/endians2,
  results,
  eth/keys,
  libp2p/[multiaddress, multicodec],
  libp2p/crypto/crypto
import ../common/enr

const MultiaddrEnrField* = "multiaddrs"

func encodeMultiaddrs*(multiaddrs: seq[MultiAddress]): seq[byte] =
  var buffer = newSeq[byte]()
  for multiaddr in multiaddrs:
    let
      raw = multiaddr.data.buffer # binary encoded multiaddr
      size = raw.len.uint16.toBytes(Endianness.bigEndian)
        # size as Big Endian unsigned 16-bit integer

    buffer.add(concat(@size, raw))

  buffer

func readBytes(
    rawBytes: seq[byte], numBytes: int, pos: var int = 0
): Result[seq[byte], cstring] =
  ## Attempts to read `numBytes` from a sequence, from
  ## position `pos`. Returns the requested slice or
  ## an error if `rawBytes` boundary is exceeded.
  ##
  ## If successful, `pos` is advanced by `numBytes`
  if rawBytes[pos ..^ 1].len() < numBytes:
    return err("insufficient bytes")

  let slicedSeq = rawBytes[pos ..< pos + numBytes]
  pos += numBytes

  return ok(slicedSeq)

func decodeMultiaddrs(buffer: seq[byte]): EnrResult[seq[MultiAddress]] =
  ## Parses a `multiaddrs` ENR field according to
  ## https://rfc.vac.dev/spec/31/
  var multiaddrs: seq[MultiAddress]

  var pos = 0
  while pos < buffer.len():
    let addrLenRaw = ?readBytes(buffer, 2, pos)
    let addrLen = uint16.fromBytesBE(addrLenRaw)
    if addrLen == 0:
      # Ensure pos always advances and we don't get stuck in infinite loop
      return err("malformed multiaddr field: invalid length")

    let addrRaw = ?readBytes(buffer, addrLen.int, pos)
    let address = MultiAddress.init(addrRaw).valueOr:
      continue # Not a valid multiaddress

    multiaddrs.add(address)

  return ok(multiaddrs)

# ENR builder extension
func stripPeerId(multiaddr: MultiAddress): MultiAddress =
  if not multiaddr.contains(multiCodec("p2p")).get():
    return multiaddr

  var cleanAddr = MultiAddress.init()
  for item in multiaddr.items:
    if item.value.protoName().get() != "p2p":
      # Add all parts except p2p peerId
      discard cleanAddr.append(item.value)

  return cleanAddr

func withMultiaddrs*(builder: var EnrBuilder, multiaddrs: seq[MultiAddress]) =
  let multiaddrs = deduplicate(multiaddrs.map(stripPeerId))
  let value = encodeMultiaddrs(multiaddrs)
  builder.addFieldPair(MultiaddrEnrField, value)

func withMultiaddrs*(builder: var EnrBuilder, multiaddrs: varargs[MultiAddress]) =
  withMultiaddrs(builder, @multiaddrs)

# ENR record accessors (e.g., Record, TypedRecord, etc.)

func multiaddrs*(record: TypedRecord): Option[seq[MultiAddress]] =
  let field = record.tryGet(MultiaddrEnrField, seq[byte])
  if field.isNone():
    return none(seq[MultiAddress])

  let decodeRes = decodeMultiaddrs(field.get()).valueOr:
    return none(seq[MultiAddress])

  some(decodeRes)
