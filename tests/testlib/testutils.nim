import testutils/unittests, chronos

template xsuite*(name: string, body: untyped) =
  discard

template suitex*(name: string, body: untyped) =
  discard

template xprocSuite*(name: string, body: untyped) =
  discard

template procSuitex*(name: string, body: untyped) =
  discard

template xtest*(name: string, body: untyped) =
  test name:
    skip()

template testx*(name: string, body: untyped) =
  test name:
    skip()

template xasyncTest*(name: string, body: untyped) =
  test name:
    skip()

template asyncTestx*(name: string, body: untyped) =
  test name:
    skip()

template waitActive*(condition: bool) =
  for i in 0 ..< 200:
    if condition:
      break
    await sleepAsync(10.millis)

  assert condition
