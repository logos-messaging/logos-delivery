import testutils/unittests, results

import waku/waku_rln_relay/rln/rln_interface
import waku/waku_rln_relay/rln/wrappers

suite "Vec_uint8":
  suite "toVecUint8":
    test "valid":
      # Given
      let bytes: seq[byte] = @[0x01, 0x02, 0x03]

      # When — wrap as a Vec_uint8 view then read the bytes back
      var vec = toVecUint8(bytes)
      let roundtrip = vecToSeq(vec)

      # Then — byte values are preserved
      check:
        roundtrip == bytes

suite "RlnConfig":
  suite "createRLNInstance":
    test "ok":
      # When we create the RLN instance (stateless build — no tree_depth arg)
      let rlnRes = createRLNInstance()

      # Then it succeeds
      check:
        rlnRes.isOk()

    test "default":
      # When we create the RLN instance
      let rlnRes = createRLNInstance()

      # Then it succeeds
      check:
        rlnRes.isOk()
