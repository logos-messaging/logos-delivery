## api_outdir
## ----------
## Tiny compile-time helper for ensuring the generated-output directory
## exists. Extracted from the (now-retired) native `api_codegen_c.nim` so
## the CBOR codegen and the CMake package emitter can share it without
## pulling in any native-codegen module.

import std/[os, macros, compilesettings]

proc detectOutputDir*(overrideOutDir = ""): string {.compileTime.} =
  ## Resolves the compiler output directory for generated artifacts. Returns
  ## the override if supplied, otherwise consults `outDir` / `outFile`
  ## query settings, falling back to the empty string.
  if overrideOutDir.len > 0:
    return overrideOutDir

  let configuredOutDir = querySetting(SingleValueSetting.outDir)
  if configuredOutDir.len > 0:
    return configuredOutDir

  let configuredOutFile = querySetting(SingleValueSetting.outFile)
  if configuredOutFile.len > 0:
    let candidateDir = splitFile(configuredOutFile).dir
    if candidateDir.len > 0:
      return candidateDir

  return ""

proc ensureGeneratedOutputDir*(outDir: string) {.compileTime, raises: [].} =
  if outDir.len == 0 or dirExists(outDir):
    return
  try:
    createDir(outDir)
  except CatchableError:
    error(
      "Failed to create generated output directory '" & outDir & "': " &
        getCurrentExceptionMsg()
    )
