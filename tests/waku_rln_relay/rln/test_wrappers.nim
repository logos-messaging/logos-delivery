import testutils/unittests, results

import waku/waku_rln_relay/rln, waku/waku_rln_relay/rln/wrappers, ./waku_rln_relay_utils

suite "membershipKeyGen":
  test "ok":
    # Given we generate valid membership keys
    let identityCredentialsRes = membershipKeyGen()

    # Then it contains valid identity credentials
    let identityCredentials = identityCredentialsRes.get()

    proc nonEmpty(x: seq[byte]): bool =
      x.len == 32 and x != newSeq[byte](32)

    check:
      identityCredentials.idTrapdoor.nonEmpty()
      identityCredentials.idNullifier.nonEmpty()
      identityCredentials.idSecretHash.nonEmpty()
      identityCredentials.idCommitment.nonEmpty()

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
