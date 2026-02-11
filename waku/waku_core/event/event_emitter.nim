type EventEmitter* = object # Placeholder for future event emitter implementation
  observers*: seq[proc(data: EventData): void]

proc initEventEmitter*(): EventEmitter =
  EventEmitter(observers: @[])

proc emitEvent*(emitter: var EventEmitter, data: EventData) =
  for observer in emitter.observers:
    asyncSpawn observer(data)

proc subscribeToEvent*(
    emitter: var EventEmitter, observer: proc(data: EventData): void
) =
  emitter.observers.add(observer)

proc unsubscribeFromEvent*(
    emitter: var EventEmitter, observer: proc(data: EventData): void
) =
  emitter.observers = emitter.observers.filterIt(it != observer)
