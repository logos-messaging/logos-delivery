import stint, chronos

import ./protocol_types

import ../waku_keystore

# Acceptable roots for merkle root validation of incoming messages
const AcceptableRootWindowSize* = 50

#Size if RLN contract root cache
const RlnContractRootCacheSize* = 5

# Minimum time between two consecutive root refreshes, to avoid refreshing the roots too often when receiving messages with old roots
# Using Linea block generation time as reference, which is around 2 seconds
const RootsRefreshMinInterval* = 2.seconds

# Minimum time between two consecutive merkle proof path freshness checks.
# Bounds how often the publish path queries chain when generating proofs at a high rate.
# Using Linea block generation time ~2s and AcceptableRootWindowSize=50, we give a generous safety margin within this
const PathCheckMinInterval* = 30.seconds

# RLN membership key and index files path
const RlnCredentialsFilename* = "rlnCredentials.txt"

# inputs of the membership contract constructor
# TODO may be able to make these constants private and put them inside the waku_rln_relay_utils
const
  # in wei
  MembershipFee* = 0.u256
  #  the current implementation of the rln lib supports a circuit for Merkle tree with depth 20
  MerkleTreeDepth* = 20
  EthClient* = "http://127.0.0.1:8540"

const
  # the size of poseidon hash output in bits
  HashBitSize* = 256
  # the size of poseidon hash output as the number hex digits
  HashHexSize* = int(HashBitSize / 4)

const
  # pre-processed "rln/waku-rln-relay/v2.0.0" to array[32, byte]
  DefaultRlnIdentifier*: RlnIdentifier = [
    114, 108, 110, 47, 119, 97, 107, 117, 45, 114, 108, 110, 45, 114, 101, 108, 97, 121,
    47, 118, 50, 46, 48, 46, 48, 0, 0, 0, 0, 0, 0, 0,
  ]
  DefaultUserMessageLimit* = UserMessageLimit(20)

const MaxClockGapSeconds* = 20.0 # the maximum clock difference between peers in seconds

# RLN Keystore defaults
const RLNAppInfo* = AppInfo(
  application: "waku-rln-relay", appIdentifier: "01234567890abcdef", version: "0.2"
)
