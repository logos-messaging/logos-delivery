{.used.}

import testutils/unittests
import logos_delivery/waku/rln/protocol_types

suite "RLN RateLimitProof codec":
  test "encode/decode round-trips, field-preserving and byte-stable":
    var proof: RateLimitProof
    for i in 0 .. 127:
      proof.proof[i] = byte(i)
    for i in 0 .. 31:
      proof.merkleRoot[i] = byte(i + 1)
      proof.epoch[i] = byte(i + 2)
      proof.shareX[i] = byte(i + 3)
      proof.shareY[i] = byte(i + 4)
      proof.nullifier[i] = byte(i + 5)
      proof.rlnIdentifier[i] = byte(i + 6)

    let encoded = proof.encode()
    let decoded = RateLimitProof.init(encoded)

    check decoded.isOk()
    let d = decoded.get()
    check:
      d == proof
      # re-encoding the decoded proof yields identical bytes
      d.encode() == encoded

  test "all-zero proof round-trips":
    let proof = RateLimitProof()
    let decoded = RateLimitProof.init(proof.encode())
    check decoded.isOk()
    check decoded.get().encode() == proof.encode()
