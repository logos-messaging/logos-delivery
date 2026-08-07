# ffi.nimble

version = "0.1.3"
author = "Institute of Free Technology"
description = "FFI framework with custom header generation"
license = "MIT or Apache License 2.0"

packageName   = "ffi"

requires "nim >= 2.2.4"
requires "chronos"
requires "chronicles"
requires "taskpools"

# Source files to include
# srcDir        = "src"
# installFiles  = @["src/ffi.nim", "mylib.h"]

# # 💡 Custom build step before installation
# before install:
#   echo "Generating custom C header..."
#   exec "nim r tools/gen_header.nim"
