import std/[macros, atomics], strformat, chronicles, chronos

macro declareLibrary*(libraryName: static[string]): untyped =
  var res = newStmtList()

  ## Generate {.pragma: exported, exportc, cdecl, raises: [].}
  res.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(ident"pragma", ident"exported"),
    ident"exportc",
    ident"cdecl",
    nnkExprColonExpr.newTree(ident"raises", nnkBracket.newTree()),
  )

  ## Generate {.pragma: callback, cdecl, raises: [], gcsafe.}
  res.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(ident"pragma", ident"callback"),
    ident"cdecl",
    nnkExprColonExpr.newTree(ident"raises", nnkBracket.newTree()),
    ident"gcsafe",
  )

  ## Generate {.passc: "-fPIC".}
  res.add nnkPragma.newTree(nnkExprColonExpr.newTree(ident"passc", newLit("-fPIC")))

  when defined(linux) and not defined(emscripten):
    # NB: under emscripten (--os:linux) a `-Wl,-soname` makes emcc build a wasm
    # SIDE module, which breaks EXPORTED_FUNCTIONS/malloc. The wasm/edge build is
    # a MAIN module, so skip the soname there.
    ## Generates {.passl: "-Wl,-soname,libwaku.so".} (considering libraryName=="waku", for example)
    let soName = fmt"-Wl,-soname,lib{libraryName}.so"
    res.add(
      newNimNode(nnkPragma).add(
        nnkExprColonExpr.newTree(ident"passl", newStrLitNode(soName))
      )
    )

  ## proc lib{libraryName}NimMain() {.importc.}
  let libNimMainName = ident(fmt"lib{libraryName}NimMain")
  let importcPragma = nnkPragma.newTree(ident"importc")
  let procDef = newProc(
    name = libNimMainName,
    params = @[ident"void"],
    pragmas = importcPragma,
    body = newEmptyNode(),
  )
  res.add(procDef)

  # Create: var initialized: Atomic[bool]
  let atomicType = nnkBracketExpr.newTree(ident("Atomic"), ident("bool"))
  let varStmt = nnkVarSection.newTree(
    nnkIdentDefs.newTree(ident("initialized"), atomicType, newEmptyNode())
  )
  res.add(varStmt)

  ## Android chronicles redirection
  let chroniclesBlock = quote:
    when defined(android) and compiles(defaultChroniclesStream.outputs[0].writer):
      defaultChroniclesStream.outputs[0].writer = proc(
          logLevel: LogLevel, msg: LogOutputStr
      ) {.raises: [].} =
        echo logLevel, msg
      result.add(chroniclesBlock)

  let procName = ident("initializeLibrary")
  let nimMainName = ident("lib" & libraryName & "NimMain")

  let initializeLibraryProc = quote:
    proc `procName`*() {.exported.} =
      if not initialized.exchange(true):
        ## Every Nim library needs to call `<yourprefix>NimMain` once exactly,
        ## to initialize the Nim runtime.
        ## Being `<yourprefix>` the value given in the optional
        ## compilation flag --nimMainPrefix:yourprefix
        `nimMainName`()
      when declared(setupForeignThreadGc):
        setupForeignThreadGc()
      when declared(nimGC_setStackBottom):
        var locals {.volatile, noinit.}: pointer
        locals = addr(locals)
        nimGC_setStackBottom(locals)

  res.add(initializeLibraryProc)

  return res
