type JsonEvent* = ref object of RootObj # https://rfc.vac.dev/spec/36/#jsonsignal-type
  eventType* {.requiresInit.}: string

method `$`*(jsonEvent: JsonEvent): string {.base.} =
  discard
  # All events should implement this
