import std/[macros]

type ConfigOptionMeta* = object
  fieldName*: string
  typeName*: string
  cliName*: string
  desc*: string
  defaultValue*: string
  command*: string

proc getPragmaValue(pragmaNode: NimNode, pragmaName: string): string {.compileTime.} =
  if pragmaNode.kind != nnkPragma:
    return ""

  for item in pragmaNode:
    if item.kind == nnkExprColonExpr and item[0].eqIdent(pragmaName):
      return item[1].repr

  return ""

proc getFieldName(fieldNode: NimNode): string {.compileTime.} =
  case fieldNode.kind
  of nnkPragmaExpr:
    if fieldNode.len >= 1:
      return getFieldName(fieldNode[0])
  of nnkPostfix:
    if fieldNode.len >= 2:
      return getFieldName(fieldNode[1])
  of nnkIdent, nnkSym:
    return fieldNode.strVal
  else:
    discard

  return fieldNode.repr

proc getFieldAndPragma(
    fieldDef: NimNode
): tuple[fieldName, typeName: string, pragmaNode: NimNode] {.compileTime.} =
  if fieldDef.kind != nnkIdentDefs:
    return ("", "", newNimNode(nnkEmpty))

  let declaredField = fieldDef[0]
  var typeNode = fieldDef[1]
  var pragmaNode = newNimNode(nnkEmpty)

  if declaredField.kind == nnkPragmaExpr:
    pragmaNode = declaredField[1]
  elif typeNode.kind == nnkPragmaExpr:
    pragmaNode = typeNode[1]
    typeNode = typeNode[0]

  return (getFieldName(declaredField), typeNode.repr, pragmaNode)

proc makeMetaNode(
    fieldName, typeName, cliName, desc, defaultValue, command: string
): NimNode {.compileTime.} =
  result = newTree(
    nnkObjConstr,
    ident("ConfigOptionMeta"),
    newTree(nnkExprColonExpr, ident("fieldName"), newLit(fieldName)),
    newTree(nnkExprColonExpr, ident("typeName"), newLit(typeName)),
    newTree(nnkExprColonExpr, ident("cliName"), newLit(cliName)),
    newTree(nnkExprColonExpr, ident("desc"), newLit(desc)),
    newTree(nnkExprColonExpr, ident("defaultValue"), newLit(defaultValue)),
    newTree(nnkExprColonExpr, ident("command"), newLit(command)),
  )

macro extractConfigOptionMeta*(T: typedesc): untyped =
  proc findFirstRecList(n: NimNode): NimNode {.compileTime.} =
    if n.kind == nnkRecList:
      return n
    for child in n:
      let found = findFirstRecList(child)
      if not found.isNil:
        return found
    return nil

  proc collectRecList(
      recList: NimNode, metas: var seq[NimNode], commandCtx: string
  ) {.compileTime.} =
    for child in recList:
      case child.kind
      of nnkIdentDefs:
        let (fieldName, typeName, pragmaNode) = getFieldAndPragma(child)
        if fieldName.len == 0:
          continue
        let cliName = block:
          let n = getPragmaValue(pragmaNode, "name")
          if n.len > 0: n else: fieldName
        let desc = getPragmaValue(pragmaNode, "desc")
        let defaultValue = getPragmaValue(pragmaNode, "defaultValue")
        metas.add(
          makeMetaNode(fieldName, typeName, cliName, desc, defaultValue, commandCtx)
        )
      of nnkRecCase:
        let discriminator = child[0]
        if discriminator.kind == nnkIdentDefs:
          let (fieldName, typeName, pragmaNode) = getFieldAndPragma(discriminator)
          if fieldName.len > 0:
            let cliName = block:
              let n = getPragmaValue(pragmaNode, "name")
              if n.len > 0: n else: fieldName
            let desc = getPragmaValue(pragmaNode, "desc")
            let defaultValue = getPragmaValue(pragmaNode, "defaultValue")
            metas.add(
              makeMetaNode(fieldName, typeName, cliName, desc, defaultValue, commandCtx)
            )

        for i in 1 ..< child.len:
          let branch = child[i]
          case branch.kind
          of nnkOfBranch:
            let branchCtx = branch[0].repr
            for j in 1 ..< branch.len:
              if branch[j].kind == nnkRecList:
                collectRecList(branch[j], metas, branchCtx)
          of nnkElse:
            for j in 0 ..< branch.len:
              if branch[j].kind == nnkRecList:
                collectRecList(branch[j], metas, commandCtx)
          else:
            discard
      else:
        discard

  let typeInst = getTypeInst(T)
  var targetType = T
  if typeInst.kind == nnkBracketExpr and typeInst.len >= 2:
    targetType = typeInst[1]

  let typeImpl = getImpl(targetType)
  let recList = findFirstRecList(typeImpl)
  if recList.isNil:
    return newTree(nnkPrefix, ident("@"), newNimNode(nnkBracket))

  var metas: seq[NimNode] = @[]
  collectRecList(recList, metas, "")

  let bracket = newNimNode(nnkBracket)
  for node in metas:
    bracket.add(node)

  result = newTree(nnkPrefix, ident("@"), bracket)
