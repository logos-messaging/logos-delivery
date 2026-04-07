{.used.}

import std/strutils, results, stew/byteutils, testutils/unittests
import waku/common/base64

suite "Waku Common - stew base64 wrapper":
  const TestData = @[
    # Test vectors from RFC 4648
    # See: https://datatracker.ietf.org/doc/html/rfc4648#section-10
    ("", Base64String("")),
    ("f", Base64String("Zg==")),
    ("fo", Base64String("Zm8=")),
    ("foo", Base64String("Zm9v")),
    ("foob", Base64String("Zm9vYg==")),
    ("fooba", Base64String("Zm9vYmE=")),
    ("foobar", Base64String("Zm9vYmFy")),

    # Custom test vectors
    ("\x01", Base64String("AQ==")),
    ("\x13", Base64String("Ew==")),
    ("\x01\x02\x03\x04", Base64String("AQIDBA==")),
  ]

  for (plaintext, encoded) in TestData:
    test "encode into base64 (" & escape(plaintext) & " -> \"" & string(encoded) & "\")":
      ## Given
      let data = plaintext

      ## When
      let encodedData = base64.encode(data)

      ## Then
      check:
        encodedData == encoded

    test "decode from base64 (\"" & string(encoded) & "\" -> " & escape(plaintext) & ")":
      ## Given
      let data = encoded

      ## When
      let decodedRes = base64.decode(data)

      ## Then
      check:
        decodedRes.isOk()

      let decoded = decodedRes.tryGet()
      check:
        decoded == toBytes(plaintext)
