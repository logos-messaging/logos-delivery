## Build recipe for liblogosdelivery, shipped in the package so dependents
## build it the same way we do.
##
##   include <logosDeliveryDir> / "library" / "build_lib.nims"
##   buildLogosDeliveryLib(packageDir = <logosDeliveryDir>)
##
## `params` on the repo wrapper is unused, as it was before the move.

import std/os

proc getMyCPU(): string =
  ## Need to set cpu more explicit manner to avoid arch issues between dependencies
  when defined(macosx) and defined(arm64):
    return " --cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" "
  elif defined(macosx) and defined(amd64):
    return " --cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" "
  elif defined(arm64):
    return " --cpu:arm64 "
  elif defined(amd64):
    return " --cpu:amd64 "
  else:
    return " "

proc getNimParams(): string =
  return " " & getEnv("NIM_PARAMS") & " "

proc buildLogosDeliveryLib*(
    packageDir = ".",
    libSubDir = "library",
    outFile = "build/liblogosdelivery.so",
    kind = "dynamic",
    srcFile = "liblogosdelivery.nim",
    mainPrefix = "liblogosdelivery",
) =
  let libDir = packageDir / libSubDir

  # Emitted by genBindings() during the build. Relative to libDir, not the cwd:
  # liblogosdelivery.h includes it as "generated/logosdelivery.h".
  let cBindingsDir = libDir / "generated"

  # `-d:ffiSrcPath` is required: without it nim-ffi derives the path with
  # `relativePath`, which needs `getcwd` at compile time and fails to build.
  let cBindingsFlags =
    " -d:ffiGenBindings -d:targetLang=c -d:ffiOutputDir=" & cBindingsDir &
    " -d:ffiSrcPath=../liblogosdelivery.nim "

  let outDir = outFile.parentDir
  if outDir.len > 0 and not dirExists(outDir):
    mkDir outDir
  mkDir cBindingsDir

  let appFlag = if kind == "static": "--app:staticlib" else: "--app:lib"

  # -Bsymbolic binds the library's references to its own symbols at link
  # time. Without it, a host process that already loads OpenSSL (e.g.
  # Node.js) interposes our statically linked BoringSSL functions and data
  # (ASN1_ITEM tables), and QUIC startup crashes in lsquic setupSSLContext
  # (issue #4085).
  let elfFlags =
    if kind == "static":
      ""
    else:
      when defined(linux): "--passL:-Wl,-Bsymbolic " else: ""

  exec "nim c" & " --out:" & outFile & " --threads:on " & appFlag &
    " --opt:speed --noMain --mm:refc --header -d:metrics --nimMainPrefix:" & mainPrefix &
    " --skipParentCfg:off -d:discv5_protocol_id=d5waku " & elfFlags & cBindingsFlags &
    getMyCPU() & getNimParams() & " " & libDir / srcFile
