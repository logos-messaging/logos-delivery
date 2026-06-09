{.used.}

import std/[os, json], chronos, testutils/unittests
import logos_delivery/waku/waku_keystore, ./testlib/common

procSuite "Credentials test suite":
  let testAppInfo = AppInfo(application: "test", appIdentifier: "1234", version: "0.1")

  test "Create keystore":
    let filepath = "./testAppKeystore.txt"
    defer:
      removeFile(filepath)

    let keystoreRes = createAppKeystore(path = filepath, appInfo = testAppInfo)

    check:
      keystoreRes.isOk()

  test "Load keystore":
    let filepath = "./testAppKeystore.txt"
    defer:
      removeFile(filepath)

    # If no keystore exists at filepath, a new one is created for appInfo and empty credentials
    let keystoreRes = loadAppKeystore(path = filepath, appInfo = testAppInfo)

    check:
      keystoreRes.isOk()

    let keystore = keystoreRes.get()

    check:
      keystore.hasKeys(["application", "appIdentifier", "version", "credentials"])
      keystore["application"].getStr() == testAppInfo.application
      keystore["appIdentifier"].getStr() == testAppInfo.appIdentifier
      keystore["version"].getStr() == testAppInfo.version
      # We assume the loaded keystore to not have credentials set (previous tests delete the keystore at filepath)
      keystore["credentials"].len() == 0

  test "Add credentials to keystore":
    let filepath = "./testAppKeystore.txt"
    defer:
      removeFile(filepath)

    # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    var
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier = randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)

    var idCredential = IdentityCredential(
      idTrapdoor: idTrapdoor,
      idNullifier: idNullifier,
      idSecretHash: idSecretHash,
      idCommitment: idCommitment,
    )

    var contract = MembershipContract(
      chainId: "5", address: "0x0123456789012345678901234567890123456789"
    )
    var index = MembershipIndex(1)

    let membershipCredential = KeystoreMembership(
      membershipContract: contract, treeIndex: index, identityCredential: idCredential
    )
    let password = "%m0um0ucoW%"

    let keystoreRes = addMembershipCredentials(
      path = filepath,
      membership = membershipCredential,
      password = password,
      appInfo = testAppInfo,
    )

    check:
      keystoreRes.isOk()

  test "Add/retrieve credentials in keystore":
    let filepath = "./testAppKeystore.txt"
    defer:
      removeFile(filepath)

    # We generate two random identity credentials (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    var
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier = randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)
      idCredential = IdentityCredential(
        idTrapdoor: idTrapdoor,
        idNullifier: idNullifier,
        idSecretHash: idSecretHash,
        idCommitment: idCommitment,
      )

    # We generate two distinct membership groups
    var contract = MembershipContract(
      chainId: "5", address: "0x0123456789012345678901234567890123456789"
    )
    var index = MembershipIndex(1)
    var membershipCredential = KeystoreMembership(
      membershipContract: contract, treeIndex: index, identityCredential: idCredential
    )

    let password = "%m0um0ucoW%"

    # We add credentials to the keystore. Note that only 3 credentials should be effectively added, since rlnMembershipCredentials3 is equal to membershipCredentials2
    let keystoreRes = addMembershipCredentials(
      path = filepath,
      membership = membershipCredential,
      password = password,
      appInfo = testAppInfo,
    )

    check:
      keystoreRes.isOk()

    # We test retrieval of credentials.
    var expectedMembership = membershipCredential
    let membershipQuery =
      KeystoreMembership(membershipContract: contract, treeIndex: index)

    var recoveredCredentialsRes = getMembershipCredentials(
      path = filepath,
      password = password,
      query = membershipQuery,
      appInfo = testAppInfo,
    )

    check:
      recoveredCredentialsRes.isOk()
      recoveredCredentialsRes.get() == expectedMembership

  test "if the keystore contains only one credential, fetch that irrespective of treeIndex":
    let filepath = "./testAppKeystore.txt"
    defer:
      removeFile(filepath)

    # We generate random identity credentials (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    let
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier = randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)
      idCredential = IdentityCredential(
        idTrapdoor: idTrapdoor,
        idNullifier: idNullifier,
        idSecretHash: idSecretHash,
        idCommitment: idCommitment,
      )

    let contract = MembershipContract(
      chainId: "5", address: "0x0123456789012345678901234567890123456789"
    )
    let index = MembershipIndex(1)
    let membershipCredential = KeystoreMembership(
      membershipContract: contract, treeIndex: index, identityCredential: idCredential
    )

    let password = "%m0um0ucoW%"

    let keystoreRes = addMembershipCredentials(
      path = filepath,
      membership = membershipCredential,
      password = password,
      appInfo = testAppInfo,
    )

    assert(keystoreRes.isOk(), $keystoreRes.error)

    # We test retrieval of credentials.
    let expectedMembership = membershipCredential
    let membershipQuery = KeystoreMembership(membershipContract: contract)

    let recoveredCredentialsRes = getMembershipCredentials(
      path = filepath,
      password = password,
      query = membershipQuery,
      appInfo = testAppInfo,
    )

    assert(recoveredCredentialsRes.isOk(), $recoveredCredentialsRes.error)
    check:
      recoveredCredentialsRes.get() == expectedMembership

  test "if the keystore contains multiple credentials, then error out if treeIndex has not been passed in":
    let filepath = "./testAppKeystore.txt"
    defer:
      removeFile(filepath)

    # We generate random identity credentials (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    let
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier = randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)
      idCredential = IdentityCredential(
        idTrapdoor: idTrapdoor,
        idNullifier: idNullifier,
        idSecretHash: idSecretHash,
        idCommitment: idCommitment,
      )

    # We generate two distinct membership groups
    let contract = MembershipContract(
      chainId: "5", address: "0x0123456789012345678901234567890123456789"
    )
    let index = MembershipIndex(1)
    var membershipCredential = KeystoreMembership(
      membershipContract: contract, treeIndex: index, identityCredential: idCredential
    )

    let password = "%m0um0ucoW%"

    let keystoreRes = addMembershipCredentials(
      path = filepath,
      membership = membershipCredential,
      password = password,
      appInfo = testAppInfo,
    )

    assert(keystoreRes.isOk(), $keystoreRes.error)

    membershipCredential.treeIndex = MembershipIndex(2)
    let keystoreRes2 = addMembershipCredentials(
      path = filepath,
      membership = membershipCredential,
      password = password,
      appInfo = testAppInfo,
    )
    assert(keystoreRes2.isOk(), $keystoreRes2.error)

    # We test retrieval of credentials.
    let membershipQuery = KeystoreMembership(membershipContract: contract)

    let recoveredCredentialsRes = getMembershipCredentials(
      path = filepath,
      password = password,
      query = membershipQuery,
      appInfo = testAppInfo,
    )

    check:
      recoveredCredentialsRes.isErr()
      recoveredCredentialsRes.error.kind == KeystoreCredentialNotFoundError

  test "if a keystore exists, but the keystoreQuery doesn't match it":
    let filepath = "./testAppKeystore.txt"
    defer:
      removeFile(filepath)

    # We generate random identity credentials (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    let
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier = randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)
      idCredential = IdentityCredential(
        idTrapdoor: idTrapdoor,
        idNullifier: idNullifier,
        idSecretHash: idSecretHash,
        idCommitment: idCommitment,
      )

    # We generate two distinct membership groups
    let contract = MembershipContract(
      chainId: "5", address: "0x0123456789012345678901234567890123456789"
    )
    let index = MembershipIndex(1)
    var membershipCredential = KeystoreMembership(
      membershipContract: contract, treeIndex: index, identityCredential: idCredential
    )

    let password = "%m0um0ucoW%"

    let keystoreRes = addMembershipCredentials(
      path = filepath,
      membership = membershipCredential,
      password = password,
      appInfo = testAppInfo,
    )

    assert(keystoreRes.isOk(), $keystoreRes.error)

    let badTestAppInfo =
      AppInfo(application: "_bad_test_", appIdentifier: "1234", version: "0.1")

    # We test retrieval of credentials.
    let membershipQuery = KeystoreMembership(membershipContract: contract)

    let recoveredCredentialsRes = getMembershipCredentials(
      path = filepath,
      password = password,
      query = membershipQuery,
      appInfo = badTestAppInfo,
    )

    check:
      recoveredCredentialsRes.isErr()
      recoveredCredentialsRes.error.kind == KeystoreJsonValueMismatchError
      recoveredCredentialsRes.error.msg ==
        "Application does not match. Expected '_bad_test_' but got 'test'"
