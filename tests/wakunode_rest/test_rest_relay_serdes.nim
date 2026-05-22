{.used.}

import results, stew/byteutils, unittest2, json_serialization
import
  waku/
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
      require(res.isOk())
      let value = res.get()
      check:
        value.payload == payload
        value.contentTopic.isSome()
        value.contentTopic.get() == "some/topic"
        value.version.isNone()
        value.timestamp.isNone()

  suite "RelayWakuMessage - encode":
    test "optional fields are none":
      # Given
      let payload = base64.encode("MESSAGE")
      let data = RelayWakuMessage(
        payload: payload,
        contentTopic: none(ContentTopic),
        version: none(Natural),
        timestamp: none(int64),
        ephemeral: none(bool),
      )

      # When
      let res = encodeIntoJsonBytes(data)

      # Then
      require(res.isOk())
      let value = res.get()
      check:
        value == toBytes("{\"payload\":\"" & $payload & "\"}")
