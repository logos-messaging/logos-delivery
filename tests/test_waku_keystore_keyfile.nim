{.used.}

import std/[json, os], stew/byteutils, testutils/unittests, chronos, eth/keys
import waku/waku_keystore, ./testlib/common

from waku/waku_noise/noise_utils import randomSeqByte

suite "KeyFile test suite":
  test "Create/Save/Load single keyfile":
    # The password we use to encrypt our secret
    let password = "randompassword"

    # The filepath were the keyfile will be stored
    let filepath = "./test.keyfile"
    defer:
      removeFile(filepath)

    # The secret
    var secret = randomSeqByte(rng[], 300)

    # We create a keyfile encrypting the secret with password
    let keyfile = createKeyFileJson(secret, password)

    check:
      keyfile.isOk()
      # We save to disk the keyfile
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We load from the file all the decrypted keyfiles encrypted under password
    var decodedKeyfiles = loadKeyFiles(filepath, password)

    check:
      decodedKeyfiles.isOk()
      # Since only one secret was stored in file, we expect only one keyfile being decrypted
      decodedKeyfiles.get().len == 1

    # We check if the decrypted secret is the same as the original secret
    let decodedSecret = decodedKeyfiles.get()[0]

    check:
      secret == decodedSecret.get()

  test "Create/Save/Load multiple keyfiles in same file":
    # We set different passwords for different keyfiles that will be stored in same file
    let password1 = string.fromBytes(randomSeqByte(rng[], 20))
    let password2 = ""
    let password3 = string.fromBytes(randomSeqByte(rng[], 20))
    var keyfile: KfResult[JsonNode]

    let filepath = "./test.keyfile"
    defer:
      removeFile(filepath)

    # We generate 6 different secrets and we encrypt them using 3 different passwords, and we store the obtained keystore

    let secret1 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret1, password1)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    let secret2 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret2, password2)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    let secret3 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret3, password3)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We encrypt secret4 with password3
    let secret4 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret4, password3)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We encrypt secret5 with password1
    let secret5 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret5, password1)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We encrypt secret6 with password1
    let secret6 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret6, password1)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # Now there are 6 keyfiles stored in filepath encrypted with 3 different passwords
    # We decrypt the keyfiles using the respective passwords and we check that the number of
    # successful decryptions corresponds to the number of secrets encrypted under that password

    var decodedKeyfilesPassword1 = loadKeyFiles(filepath, password1)
    check:
      decodedKeyfilesPassword1.isOk()
      decodedKeyfilesPassword1.get().len == 3
    var decodedSecretsPassword1 = decodedKeyfilesPassword1.get()

    var decodedKeyfilesPassword2 = loadKeyFiles(filepath, password2)
    check:
      decodedKeyfilesPassword2.isOk()
      decodedKeyfilesPassword2.get().len == 1
    var decodedSecretsPassword2 = decodedKeyfilesPassword2.get()

    var decodedKeyfilesPassword3 = loadKeyFiles(filepath, password3)
    check:
      decodedKeyfilesPassword3.isOk()
      decodedKeyfilesPassword3.get().len == 2
    var decodedSecretsPassword3 = decodedKeyfilesPassword3.get()

    # We check if the corresponding secrets are correct
    check:
      # Secrets encrypted with password 1
      secret1 == decodedSecretsPassword1[0].get()
      secret5 == decodedSecretsPassword1[1].get()
      secret6 == decodedSecretsPassword1[2].get()
      # Secrets encrypted with password 2
      secret2 == decodedSecretsPassword2[0].get()
      # Secrets encrypted with password 3
      secret3 == decodedSecretsPassword3[0].get()
      secret4 == decodedSecretsPassword3[1].get()

# The following tests are originally from the nim-eth keyfile tests module https://github.com/status-im/nim-eth/blob/master/tests/keyfile/test_keyfile.nim
# and are slightly adapted to test backwards compatibility with nim-eth implementation of our customized version of the utils/keyfile module
# Note: the original nim-eth "Create/Save/Load test" is redefined and expanded above in "KeyFile test suite"
suite "KeyFile test suite (adapted from nim-eth keyfile tests)":
  # Testvectors originally from https://github.com/status-im/nim-eth/blob/fef47331c37ee8abb8608037222658737ff498a6/tests/keyfile/test_keyfile.nim#L22-L168
  let TestVectors = [
    %*{
      "keyfile": {
        "crypto": {
          "cipher": "aes-128-ctr",
          "cipherparams": {"iv": "6087dab2f9fdbbfaddc31a909735c1e6"},
          "ciphertext":
            "5318b4d5bcd28de64ee5559e671353e16f075ecae9f99c7a79a38af5f869aa46",
          "kdf": "pbkdf2",
          "kdfparams": {
            "c": 262144,
            "dklen": 32,
            "prf": "hmac-sha256",
            "salt": "ae3cd4e7013836a3df6bd7241b12db061dbe2c6785853cce422d148a624ce0bd",
          },
          "mac": "517ead924a9d0dc3124507e3393d175ce3ff7c1e96529c6c555ce9e51205e9b2",
        },
        "id": "3198bc9c-6672-5ab3-d995-4942343ae5b6",
        "version": 3,
      },
      "name": "test1",
      "password": "testpassword",
      "priv": "7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d",
    },
    %*{
      "keyfile": {
        "version": 3,
        "crypto": {
          "ciphertext":
            "ee75456c006b1e468133c5d2a916bacd3cf515ced4d9b021b5c59978007d1e87",
          "version": 1,
          "kdf": "pbkdf2",
          "kdfparams": {
            "dklen": 32,
            "c": 262144,
            "prf": "hmac-sha256",
            "salt": "504490577620f64f43d73f29479c2cf0",
          },
          "mac": "196815708465de9af7504144a1360d08874fc3c30bb0e648ce88fbc36830d35d",
          "cipherparams": {"iv": "514ccc8c4fb3e60e5538e0cf1e27c233"},
          "cipher": "aes-128-ctr",
        },
        "id": "98d193c7-5174-4c7c-5345-c1daf95477b5",
      },
      "name": "python_generated_test_with_odd_iv",
      "password": "foo",
      "priv": "0101010101010101010101010101010101010101010101010101010101010101",
    },
    %*{
      "keyfile": {
        "version": 3,
        "crypto": {
          "ciphertext":
            "d69313b6470ac1942f75d72ebf8818a0d484ac78478a132ee081cd954d6bd7a9",
          "cipherparams": {"iv": "ffffffffffffffffffffffffffffffff"},
          "kdf": "pbkdf2",
          "kdfparams": {
            "dklen": 32,
            "c": 262144,
            "prf": "hmac-sha256",
            "salt": "c82ef14476014cbf438081a42709e2ed",
          },
          "mac": "cf6bfbcc77142a22c4a908784b4a16f1023a1d0e2aff404c20158fa4f1587177",
          "cipher": "aes-128-ctr",
          "version": 1,
        },
        "id": "abb67040-8dbe-0dad-fc39-2b082ef0ee5f",
      },
      "name": "evilnonce",
      "password": "bar",
      "priv": "0202020202020202020202020202020202020202020202020202020202020202",
    },
    %*{
      "keyfile": {
        "version": 3,
        "crypto": {
          "cipher": "aes-128-ctr",
          "cipherparams": {"iv": "83dbcc02d8ccb40e466191a123791e0e"},
          "ciphertext":
            "d172bf743a674da9cdad04534d56926ef8358534d458fffccd4e6ad2fbde479c",
          "kdf": "scrypt",
          "kdfparams": {
            "dklen": 32,
            "n": 262144,
            "r": 1,
            "p": 8,
            "salt": "ab0c7876052600dd703518d6fc3fe8984592145b591fc8fb5c6d43190334ba19",
          },
          "mac": "2103ac29920d71da29f15d75b4a16dbe95cfd7ff8faea1056c33131d846e3097",
        },
        "id": "3198bc9c-6672-5ab3-d995-4942343ae5b6",
      },
      "name": "test2",
      "password": "testpassword",
      "priv": "7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d",
    },
    %*{
      "keyfile": {
        "version": 3,
        "address": "460121576cc7df020759730751f92bd62fd78dd6",
        "crypto": {
          "ciphertext":
            "54ae683c6287fa3d58321f09d56e26d94e58a00d4f90bdd95782ae0e4aab618b",
          "cipherparams": {"iv": "681679cdb125bba9495d068b002816a4"},
          "cipher": "aes-128-ctr",
          "kdf": "scrypt",
          "kdfparams": {
            "dklen": 32,
            "salt": "c3407f363fce02a66e3c4bf4a8f6b7da1c1f54266cef66381f0625c251c32785",
            "n": 8192,
            "r": 8,
            "p": 1,
          },
          "mac": "dea6bdf22a2f522166ed82808c22a6311e84c355f4bbe100d4260483ff675a46",
        },
        "id": "0eb785e0-340a-4290-9c42-90a11973ee47",
      },
      "name": "mycrypto",
      "password": "foobartest121",
      "priv": "05a4d3eb46c742cb8850440145ce70cbc80b59f891cf5f50fd3e9c280b50c4e4",
    },
    %*{
      "keyfile": {
        "crypto": {
          "cipher": "aes-128-ctr",
          "cipherparams": {"iv": "7e7b02d2b4ef45d6c98cb885e75f48d5"},
          "ciphertext":
            "a7a5743a6c7eb3fa52396bd3fd94043b79075aac3ccbae8e62d3af94db00397c",
          "kdf": "scrypt",
          "kdfparams": {
            "dklen": 32,
            "n": 8192,
            "p": 1,
            "r": 8,
            "salt": "247797c7a357b707a3bdbfaa55f4c553756bca09fec20ddc938e7636d21e4a20",
          },
          "mac": "5a3ba5bebfda2c384586eda5fcda9c8397d37c9b0cc347fea86525cf2ea3a468",
        },
        "address": "0b6f2de3dee015a95d3330dcb7baf8e08aa0112d",
        "id": "3c8efdd6-d538-47ec-b241-36783d3418b9",
        "version": 3,
      },
      "password": "moomoocow",
      "priv": "21eac69b9a52f466bfe9047f0f21c9caf3a5cdaadf84e2750a9b3265d450d481",
      "name": "eth-keyfile-conftest",
    },
  ]

  test "Testing nim-eth test vectors":
    var secret: KfResult[seq[byte]]
    var expectedSecret: seq[byte]

    for i in 0 ..< TestVectors.len:
      # Decryption with correct password
      expectedSecret = decodeHex(TestVectors[i].getOrDefault("priv").getStr())
      secret = decodeKeyFileJson(
        TestVectors[i].getOrDefault("keyfile"),
        TestVectors[i].getOrDefault("password").getStr(),
      )
      check:
        secret.isOk()
        secret.get() == expectedSecret

      # Decryption with wrong password
      secret =
        decodeKeyFileJson(TestVectors[i].getOrDefault("keyfile"), "wrongpassword")

      check:
        secret.isErr()
        secret.error == KeyFileError.KeyfileIncorrectMac

  test "Wrong mac in keyfile":
    # This keyfile is the same as the first one in TestVectors,
    # but the last byte of mac is changed to 00.
    # While ciphertext is the correct encryption of priv under password,
    # mac verfication should fail and nothing will be decrypted
    let keyfileWrongMac = %*{
      "keyfile": {
        "crypto": {
          "cipher": "aes-128-ctr",
          "cipherparams": {"iv": "6087dab2f9fdbbfaddc31a909735c1e6"},
          "ciphertext":
            "5318b4d5bcd28de64ee5559e671353e16f075ecae9f99c7a79a38af5f869aa46",
          "kdf": "pbkdf2",
          "kdfparams": {
            "c": 262144,
            "dklen": 32,
            "prf": "hmac-sha256",
            "salt": "ae3cd4e7013836a3df6bd7241b12db061dbe2c6785853cce422d148a624ce0bd",
          },
          "mac": "517ead924a9d0dc3124507e3393d175ce3ff7c1e96529c6c555ce9e51205e900",
        },
        "id": "3198bc9c-6672-5ab3-d995-4942343ae5b6",
        "version": 3,
      },
      "name": "test1",
      "password": "testpassword",
      "priv": "7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d",
    }

    # Decryption with correct password
    let expectedSecret = decodeHex(keyfileWrongMac.getOrDefault("priv").getStr())
    let secret = decodeKeyFileJson(
      keyfileWrongMac.getOrDefault("keyfile"),
      keyfileWrongMac.getOrDefault("password").getStr(),
    )
    check:
      secret.isErr()
      secret.error == KeyFileError.KeyFileIncorrectMac

  test "Scrypt keyfiles":
    let
      expectedSecret = randomSeqByte(rng[], 300)
      password = "miawmiawcat"

      # By default, keyfiles' encryption key is derived from password using PBKDF2.
      # Here we test keyfiles encypted with a key derived from password using scrypt
      jsonKeyfile = createKeyFileJson(expectedSecret, password, 3, AES128CTR, SCRYPT)

    check:
      jsonKeyfile.isOk()

    let secret = decodeKeyFileJson(jsonKeyfile.get(), password)

    check:
      secret.isOk()
      secret.get() == expectedSecret

  test "Load non-existent keyfile test":
    check:
      loadKeyFiles("nonexistant.keyfile", "password").error ==
        KeyFileError.KeyfileDoesNotExist
