{.used.}

import results, stew/byteutils, testutils/unittests, json_serialization
import
  logos_delivery/waku/rest_api/endpoint/serdes,
  logos_delivery/waku/rest_api/endpoint/debug/types

suite "Waku v2 REST API - Debug -  serialization":
  suite "DebugWakuInfo - decode":
    test "optional field is not provided":
      # Given
      let jsonBytes = toBytes("""{ "listenAddresses":["123"] }""")

      # When
      let res = decodeFromJsonBytes(DebugWakuInfo, jsonBytes, requireAllFields = true)

      # Then
      require(res.isOk())
      let value = res.get()
      check:
        value.listenAddresses == @["123"]
        value.enrUri.isNone()

    test "unknown field is skipped":
      # A newer node can add a field. An older client logs it and decodes the
      # rest, instead of failing on the value it did not read.
      let jsonBytes = toBytes(
        """{ "listenAddresses":["123"], "added":[1,{"nested":2}], "enrUri":"enr:-x" }"""
      )

      let res = decodeFromJsonBytes(DebugWakuInfo, jsonBytes, requireAllFields = true)

      require(res.isOk())
      let value = res.get()
      check:
        value.listenAddresses == @["123"]
        value.enrUri == Opt.some("enr:-x")

  suite "DebugWakuInfo - encode":
    test "optional field is none":
      # Given
      let data = DebugWakuInfo(listenAddresses: @["GO"], enrUri: Opt.none(string))

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      require(res.isOk())
      let value = res.get()
      check:
        value == toBytes("""{"listenAddresses":["GO"]}""")
