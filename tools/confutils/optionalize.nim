{.push raises: [].}

import std/[macros, options]

proc isOptionType(n: NimNode): bool =
  if n.kind == nnkBracketExpr and n.len >= 1:
    let head = n[0]
    return head.eqIdent("Option")
  return false

proc unwrapName(n: NimNode): NimNode =
  var cur = n
  if cur.kind == nnkPragmaExpr:
    cur = cur[0]
  if cur.kind == nnkPostfix:
    cur = cur[1]
  return cur

proc collectFields(rec: NimNode, target: NimNode, excluded: seq[string]) =
  for child in rec:
    case child.kind
    of nnkIdentDefs:
      let nameNode = child[0]
      let fieldType = child[^2]
      let plainName = unwrapName(nameNode)
      if plainName.kind notin {nnkIdent, nnkSym}:
        continue
      if $plainName in excluded:
        continue
      let newType =
        if isOptionType(fieldType):
          fieldType
        else:
          nnkBracketExpr.newTree(ident("Option"), fieldType)
      let exported = postfix(ident($plainName), "*")
      target.add(newIdentDefs(exported, newType, newEmptyNode()))
    of nnkRecCase:
      for branch in child[1 ..^ 1]:
        case branch.kind
        of nnkOfBranch:
          collectFields(branch[^1], target, excluded)
        of nnkElse:
          collectFields(branch[0], target, excluded)
        else:
          discard
    of nnkRecList:
      collectFields(child, target, excluded)
    else:
      discard

macro optionalizeType*(
    newName: untyped, source: typedesc, exclude: static[openArray[string]] = []
): untyped =
  var typImpl = source.getTypeImpl
  if typImpl.kind == nnkBracketExpr and typImpl.len >= 2:
    typImpl = typImpl[1].getTypeImpl
  if typImpl.kind != nnkObjectTy:
    error("optionalizeType: expected object type, got " & $typImpl.kind, source)

  var excluded: seq[string] = @[]
  for e in exclude:
    excluded.add(e)

  let recList = typImpl[2]
  let newRecList = newNimNode(nnkRecList)
  collectFields(recList, newRecList, excluded)

  let typeDef = nnkTypeDef.newTree(
    postfix(newName, "*"),
    newEmptyNode(),
    nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), newRecList),
  )

  result = nnkTypeSection.newTree(typeDef)
