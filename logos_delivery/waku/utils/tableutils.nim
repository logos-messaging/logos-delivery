import std/tables, stew/templateutils

template keepItIf*[A, B](tableParam: var Table[A, B], itPredicate: untyped) =
  bind evalTemplateParamOnce
  evalTemplateParamOnce(tableParam, t):
    var itemsToDelete: seq[A]
    var key {.inject.}: A
    var val {.inject.}: B

    for k, v in t.mpairs():
      key = k
      val = v
      if not itPredicate:
        itemsToDelete.add(key)

    for item in itemsToDelete:
      t.del(item)

template keepItIf*[A, B](tableParam: var TableRef[A, B], itPredicate: untyped) =
  bind evalTemplateParamOnce
  evalTemplateParamOnce(tableParam, t):
    var itemsToDelete: seq[A]
    let key {.inject.}: A
    let val {.inject.}: B

    for k, v in t[].mpairs():
      key = k
      val = v
      if not itPredicate:
        itemsToDelete.add(key)

    for item in itemsToDelete:
      t[].del(item)
