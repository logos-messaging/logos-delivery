import std/[json, macros]

type JsonEvent*[T] = ref object
  eventType*: string
  payload*: T

macro toFlatJson*(event: JsonEvent): JsonNode =
  ## Serializes JsonEvent[T] to flat JSON with eventType first, 
  ## followed by all fields from T's payload
  result = quote:
    var jsonObj = newJObject()
    jsonObj["eventType"] = %`event`.eventType

    # Serialize payload fields into the same object (flattening)
    let payloadJson = %`event`.payload
    for key, val in payloadJson.pairs:
      jsonObj[key] = val

    jsonObj

proc `$`*[T](event: JsonEvent[T]): string =
  $toFlatJson(event)

proc newJsonEvent*[T](eventType: string, payload: T): JsonEvent[T] =
  ## Creates a new JsonEvent with the given eventType and payload.
  ## The payload's fields will be flattened into the JSON output.
  JsonEvent[T](eventType: eventType, payload: payload)
