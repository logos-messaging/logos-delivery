# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

import os

let rlnLib = getCurrentDir() / "build" / "librln.a"
echo "RLN lib path: ", rlnLib
switch("passL", rlnLib)
switch("passL", "-lm")
