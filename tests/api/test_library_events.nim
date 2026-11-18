{.used.}

import std/json
import testutils/unittests

import logos_delivery/api/events/messaging_client_events
import library/json_event

suite "Library events":
  test "the JSON of an error event gives the kind by its name":
    let event = MessageErrorEvent(
      messageHash: "0x01", kind: MessageErrorKind.NotStored, error: "boom"
    )
    check $newJsonEvent("message_error", event) ==
      """{"eventType":"message_error","messageHash":"0x01","kind":"NotStored","error":"boom"}"""
