{.push raises: [].}

## Setup script to generate RLN credentials and shared Merkle tree for mix nodes.
##
## This script:
## 1. Generates credentials for each node (identified by peer ID)
## 2. Registers all credentials in a shared Merkle tree
## 3. Saves the tree to rln_tree.db
## 4. Saves individual keystores named by peer ID
##
## Usage: nim c -r setup_credentials.nim

import std/[os, strformat, options], chronicles, chronos, results

import
  mix_rln_spam_protection/credentials,
  mix_rln_spam_protection/group_manager,
  mix_rln_spam_protection/rln_interface,
  mix_rln_spam_protection/types

const
  KeystorePassword = "mix-rln-password" # Must match protocol.nim
  DefaultUserMessageLimit = 100'u64 # Network-wide default rate limit
  SpammerUserMessageLimit = 3'u64 # Lower limit for spammer testing

  # Peer IDs derived from nodekeys in config files
  # config.toml:   nodekey = "f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a"
  # config1.toml:  nodekey = "09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684"
  # config2.toml:  nodekey = "ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e"
  # config3.toml:  nodekey = "42f96f29f2d6670938b0864aced65a332dcf5774103b4c44ec4d0ea4ef3c47d6"
  # config4.toml:  nodekey = "3ce887b3c34b7a92dd2868af33941ed1dbec4893b054572cd5078da09dd923d4"
  # chat2mix.sh:   nodekey = "cb6fe589db0e5d5b48f7e82d33093e4d9d35456f4aaffc2322c473a173b2ac49"
  # chat2mix1.sh:  nodekey = "35eace7ccb246f20c487e05015ca77273d8ecaed0ed683de3d39bf4f69336feb"

  # Node info: (peerId, userMessageLimit)
  NodeConfigs = [
    ("16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o", DefaultUserMessageLimit),
      # config.toml (service node)
    ("16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF", DefaultUserMessageLimit),
      # config1.toml (mix node 1)
    ("16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA", DefaultUserMessageLimit),
      # config2.toml (mix node 2)
    ("16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f", DefaultUserMessageLimit),
      # config3.toml (mix node 3)
    ("16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu", DefaultUserMessageLimit),
      # config4.toml (mix node 4)
    ("16Uiu2HAm1QxSjNvNbsT2xtLjRGAsBLVztsJiTHr9a3EK96717hpj", DefaultUserMessageLimit),
      # chat2mix client 1
    ("16Uiu2HAmC9h26U1C83FJ5xpE32ghqya8CaZHX1Y7qpfHNnRABscN", DefaultUserMessageLimit),
      # chat2mix client 2
  ]

proc setupCredentialsAndTree() {.async.} =
  ## Generate credentials for all nodes and create a shared tree

  echo "=== RLN Credentials Setup ==="
  echo "Generating credentials for ", NodeConfigs.len, " nodes...\n"

  # Generate credentials for all nodes
  var allCredentials:
    seq[tuple[peerId: string, cred: IdentityCredential, rateLimit: uint64]]
  for (peerId, rateLimit) in NodeConfigs:
    let cred = generateCredentials().valueOr:
      echo "Failed to generate credentials for ", peerId, ": ", error
      quit(1)

    allCredentials.add((peerId: peerId, cred: cred, rateLimit: rateLimit))
    echo "Generated credentials for ", peerId
    echo "  idCommitment: ", cred.idCommitment.toHex()[0 .. 15], "..."
    echo "  userMessageLimit: ", rateLimit

  echo ""

  # Create a group manager directly to build the tree
  let rlnInstance = newRLNInstance().valueOr:
    echo "Failed to create RLN instance: ", error
    quit(1)

  let groupManager = newOffchainGroupManager(rlnInstance, "/mix/rln/membership/v1")

  # Initialize the group manager
  let initRes = await groupManager.init()
  if initRes.isErr:
    echo "Failed to initialize group manager: ", initRes.error
    quit(1)

  # Register all credentials in the tree with their specific rate limits
  echo "Registering all credentials in the Merkle tree..."
  for i, entry in allCredentials:
    let index = (
      await groupManager.registerWithLimit(entry.cred.idCommitment, entry.rateLimit)
    ).valueOr:
      echo "Failed to register credential for ", entry.peerId, ": ", error
      quit(1)
    echo "  Registered ",
      entry.peerId, " at index ", index, " (limit: ", entry.rateLimit, ")"

  echo ""

  # Save the tree to disk
  echo "Saving tree to rln_tree.db..."
  let saveRes = groupManager.saveTreeToFile("rln_tree.db")
  if saveRes.isErr:
    echo "Failed to save tree: ", saveRes.error
    quit(1)
  echo "Tree saved successfully!"

  echo ""

  # Save each credential to a keystore file named by peer ID
  echo "Saving keystores..."
  for i, entry in allCredentials:
    let keystorePath = &"rln_keystore_{entry.peerId}.json"

    # Save with membership index and rate limit
    let saveResult = saveKeystore(
      entry.cred,
      KeystorePassword,
      keystorePath,
      some(MembershipIndex(i)),
      some(entry.rateLimit),
    )
    if saveResult.isErr:
      echo "Failed to save keystore for ", entry.peerId, ": ", saveResult.error
      quit(1)
    echo "  Saved: ", keystorePath, " (limit: ", entry.rateLimit, ")"

  echo ""
  echo "=== Setup Complete ==="
  echo "  Tree file: rln_tree.db (", NodeConfigs.len, " members)"
  echo "  Keystores: rln_keystore_{peerId}.json"
  echo "  Password: ", KeystorePassword
  echo "  Default rate limit: ", DefaultUserMessageLimit
  echo "  Spammer rate limit: ", SpammerUserMessageLimit
  echo ""
  echo "Note: All nodes must use the same rln_tree.db file."

when isMainModule:
  waitFor setupCredentialsAndTree()
