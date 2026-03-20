import std/macros

type ParsedBrokerType* = object
  ## Result of parsing the single `type` definition inside a broker macro body.
  ##
  ## - `typeIdent`: base identifier for the declared type name
  ## - `objectDef`: exported type definition RHS (inline object fields exported;
  ##   non-object types wrapped in `distinct` unless already distinct)
  ## - `isRefObject`: true only for inline `ref object` definitions
  ## - `hasInlineFields`: true for inline `object` / `ref object`
  ## - `fieldNames`/`fieldTypes`: populated only when `collectFieldInfo = true`
  typeIdent*: NimNode
  objectDef*: NimNode
  isRefObject*: bool
  hasInlineFields*: bool
  fieldNames*: seq[NimNode]
  fieldTypes*: seq[NimNode]

proc sanitizeIdentName*(node: NimNode): string =
  var raw = $node
  var sanitizedName = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_':
      sanitizedName.add(ch)
    else:
      sanitizedName.add('_')
  sanitizedName

proc ensureFieldDef*(node: NimNode) =
  if node.kind != nnkIdentDefs or node.len < 3:
    error("Expected field definition of the form `name: Type`", node)
  let typeSlot = node.len - 2
  if node[typeSlot].kind == nnkEmpty:
    error("Field `" & $node[0] & "` must declare a type", node)

proc exportIdentNode*(node: NimNode): NimNode =
  case node.kind
  of nnkIdent:
    postfix(copyNimTree(node), "*")
  of nnkPostfix:
    node
  else:
    error("Unsupported identifier form in field definition", node)

proc baseTypeIdent*(defName: NimNode): NimNode =
  case defName.kind
  of nnkIdent:
    defName
  of nnkAccQuoted:
    if defName.len != 1:
      error("Unsupported quoted identifier", defName)
    defName[0]
  of nnkPostfix:
    baseTypeIdent(defName[1])
  of nnkPragmaExpr:
    baseTypeIdent(defName[0])
  else:
    error("Unsupported type name in broker definition", defName)

proc ensureDistinctType*(rhs: NimNode): NimNode =
  ## For PODs / aliases / externally-defined types, wrap in `distinct` unless
  ## it's already distinct.
  if rhs.kind == nnkDistinctTy:
    return copyNimTree(rhs)
  newTree(nnkDistinctTy, copyNimTree(rhs))

proc cloneParams*(params: seq[NimNode]): seq[NimNode] =
  ## Deep copy parameter definitions so they can be inserted in multiple places.
  result = @[]
  for param in params:
    result.add(copyNimTree(param))

proc collectParamNames*(params: seq[NimNode]): seq[NimNode] =
  ## Extract all identifier symbols declared across IdentDefs nodes.
  result = @[]
  for param in params:
    assert param.kind == nnkIdentDefs
    for i in 0 ..< param.len - 2:
      let nameNode = param[i]
      if nameNode.kind == nnkEmpty:
        continue
      result.add(ident($nameNode))

proc parseSingleTypeDef*(
    body: NimNode,
    macroName: string,
    allowRefToNonObject = false,
    collectFieldInfo = false,
): ParsedBrokerType =
  ## Parses exactly one `type` definition from a broker macro body.
  ##
  ## Supported RHS:
  ## - inline `object` / `ref object` (fields are auto-exported)
  ## - non-object types / aliases / externally-defined types (wrapped in `distinct`)
  ## - optionally: `ref SomeType` when `allowRefToNonObject = true`
  var typeIdent: NimNode = nil
  var objectDef: NimNode = nil
  var isRefObject = false
  var hasInlineFields = false
  var fieldNames: seq[NimNode] = @[]
  var fieldTypes: seq[NimNode] = @[]

  for stmt in body:
    if stmt.kind != nnkTypeSection:
      continue
    for def in stmt:
      if def.kind != nnkTypeDef:
        continue
      if not typeIdent.isNil():
        error("Only one type may be declared inside " & macroName, def)
      typeIdent = baseTypeIdent(def[0])
      let rhs = def[2]

      case rhs.kind
      of nnkObjectTy:
        let recList = rhs[2]
        if recList.kind != nnkRecList:
          error(macroName & " object must declare a standard field list", rhs)
        var exportedRecList = newTree(nnkRecList)
        for field in recList:
          case field.kind
          of nnkIdentDefs:
            ensureFieldDef(field)
            if collectFieldInfo:
              let fieldTypeNode = field[field.len - 2]
              for i in 0 ..< field.len - 2:
                let baseFieldIdent = baseTypeIdent(field[i])
                fieldNames.add(copyNimTree(baseFieldIdent))
                fieldTypes.add(copyNimTree(fieldTypeNode))
            var cloned = copyNimTree(field)
            for i in 0 ..< cloned.len - 2:
              cloned[i] = exportIdentNode(cloned[i])
            exportedRecList.add(cloned)
          of nnkEmpty:
            discard
          else:
            error(
              macroName & " object definition only supports simple field declarations",
              field,
            )
        objectDef = newTree(
          nnkObjectTy, copyNimTree(rhs[0]), copyNimTree(rhs[1]), exportedRecList
        )
        isRefObject = false
        hasInlineFields = true
      of nnkRefTy:
        if rhs.len != 1:
          error(macroName & " ref type must have a single base", rhs)
        if rhs[0].kind == nnkObjectTy:
          let obj = rhs[0]
          let recList = obj[2]
          if recList.kind != nnkRecList:
            error(macroName & " object must declare a standard field list", obj)
          var exportedRecList = newTree(nnkRecList)
          for field in recList:
            case field.kind
            of nnkIdentDefs:
              ensureFieldDef(field)
              if collectFieldInfo:
                let fieldTypeNode = field[field.len - 2]
                for i in 0 ..< field.len - 2:
                  let baseFieldIdent = baseTypeIdent(field[i])
                  fieldNames.add(copyNimTree(baseFieldIdent))
                  fieldTypes.add(copyNimTree(fieldTypeNode))
              var cloned = copyNimTree(field)
              for i in 0 ..< cloned.len - 2:
                cloned[i] = exportIdentNode(cloned[i])
              exportedRecList.add(cloned)
            of nnkEmpty:
              discard
            else:
              error(
                macroName & " object definition only supports simple field declarations",
                field,
              )
          let exportedObjectType = newTree(
            nnkObjectTy, copyNimTree(obj[0]), copyNimTree(obj[1]), exportedRecList
          )
          objectDef = newTree(nnkRefTy, exportedObjectType)
          isRefObject = true
          hasInlineFields = true
        elif allowRefToNonObject:
          ## `ref SomeType` (SomeType can be defined elsewhere)
          objectDef = ensureDistinctType(rhs)
          isRefObject = false
          hasInlineFields = false
        else:
          error(macroName & " ref object must wrap a concrete object definition", rhs)
      else:
        ## Non-object type / alias.
        objectDef = ensureDistinctType(rhs)
        isRefObject = false
        hasInlineFields = false

  if typeIdent.isNil():
    error(macroName & " body must declare exactly one type", body)

  result = ParsedBrokerType(
    typeIdent: typeIdent,
    objectDef: objectDef,
    isRefObject: isRefObject,
    hasInlineFields: hasInlineFields,
    fieldNames: fieldNames,
    fieldTypes: fieldTypes,
  )
