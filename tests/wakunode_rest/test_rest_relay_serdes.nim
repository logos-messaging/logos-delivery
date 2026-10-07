{.used.}

import results, stew/byteutils, unittest2, json_serialization
import
  logos_delivery/waku/
    [common/base64, rest_api/endpoint/serdes, rest_api/endpoint/relay/types, waku_core]

suite "Waku v2 Rest API - Relay - serialization":
  suite "RelayWakuMessage - decode":
    test "optional fields are not provided":
      # Given
      let payload = base64.encode("MESSAGE")
      let jsonBytes =
        toBytes("{\"payload\":\"" & $payload & "\",\"contentTopic\":\"some/topic\"}")

      # When
      let res =
        decodeFromJsonBytes(RelayWakuMessage, jsonBytes, requireAllFields = true)

      # Then
      check res.isOk()
      let value = res.get(RelayWakuMessage())
      check:
        value.payload == payload
        value.contentTopic.isSome()
        value.contentTopic.get() == "some/topic"
        value.version.isNone()
        value.timestamp.isNone()

    test "unknown fields are ignored":
      # Given
      let payload = base64.encode("MESSAGE")
      let known = "\"payload\":\"" & $payload & "\",\"contentTopic\":\"some/topic\""
      let expected = decodeFromJsonBytes(
        RelayWakuMessage, toBytes("{" & known & "}"), requireAllFields = true
      )
      require(expected.isOk())

      let unknownValues =
        @["\"some string\"", "{\"a\":{\"b\":[1,2]}}", "[1,{\"c\":\"d\"},[]]", "42"]

      for unknownValue in unknownValues:
        let unknownField = "\"unknownField\":" & unknownValue
        for jsonStr in [
          "{" & unknownField & "," & known & "}", "{" & known & "," & unknownField & "}"
        ]:
          # When
          let res = decodeFromJsonBytes(
            RelayWakuMessage, toBytes(jsonStr), requireAllFields = true
          )

          # Then
          check:
            res.isOk()
            res.get() == expected.get()

  suite "RelayWakuMessage - encode":
    test "optional fields are none":
      # Given
      let payload = base64.encode("MESSAGE")
      let data = RelayWakuMessage(
        payload: payload,
        contentTopic: Opt.none(ContentTopic),
        version: Opt.none(Natural),
        timestamp: Opt.none(int64),
        ephemeral: Opt.none(bool),
      )

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      check res.isOk()
      let value = res.get(newSeq[byte]())
      check:
        value == toBytes("{\"payload\":\"" & $payload & "\"}")
