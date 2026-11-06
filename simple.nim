import chronos

proc myProcA() {.noSideEffect.} =
  echo "Starting myProc"

func myProc() =
  echo "Starting myProc AAAAA"

iterator myIterator(): int =
  for i in 0 .. 4:
    yield i

  echo "Iterator done."

when isMainModule:
  for value in myIterator():
    echo value

  myProcA()
  myProc()

# iterator and yield

# proc myProc(): Future[void] {.stackTrace: off, raises: [], gcsafe.} =
#   iterator myProc_1040187396(chronosInternalRetFuture: FutureBase): FutureBase {.
#       closure, gcsafe, raises: [].} =
#     template result(): auto {.used.} =
#       {.fatal: "You should not reference the `result` variable inside" &
#           " a void async proc".}

#     var closureSucceeded_1040187395 = true
#     try:
#       await sleepAsync(1.milliseconds)
#     except CancelledError:
#       closureSucceeded_1040187395 = false
#       cancelAndSchedule(cast[Future[void]](chronosInternalRetFuture))
#     except CatchableError as exc:
#       closureSucceeded_1040187395 = false
#       fail(cast[Future[void]](chronosInternalRetFuture), exc)
#     except Defect as exc:
#       closureSucceeded_1040187395 = false
#       raise exc
#     finally:
#       if closureSucceeded_1040187395:
#         complete(cast[Future[void]](chronosInternalRetFuture))

#   let resultFuture = newFuture[void]("myProc")
#   resultFuture.internalClosure = myProc_1040187396
#   futureContinue(resultFuture)
#   return resultFuture
