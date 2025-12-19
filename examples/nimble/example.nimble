# Package

version = "0.1.0"
author = "fryorcraken"
description = "Test Waku with nimble"
license = "MIT"
srcDir = "src"
bin = @["example"]

# Dependencies

requires "chronos"
requires "results"
requires "waku#44bfddb245e30eeab850730dee67c41cbe7f7252"

import os

proc ensureRln(libFile: string = "build/librln.a", version = "v0.8.0") =
  if not fileExists(libFile):
    echo "Building RLN library..."
    let buildDir = parentDir(parentDir(getCurrentDir())) & "/vendor/zerokit"
    let outFile = libFile

    let outDir = parentDir(outFile)
    if not dirExists(outDir):
      mkDir(outDir) # Ensure build directory exists

    exec "bash ../../scripts/build_rln.sh " & buildDir & " " & version & " " & outFile
  else:
    echo "RLN library already exists: " & libFile

before build:
  ensureRln()
