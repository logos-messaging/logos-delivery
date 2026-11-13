## GCC miscompiles Nim's ORC output when LTO is on: its tree-SRA pass mishandles
## functions that IPA-ICF (identical code folding) merged across types, such as the
## `=wasMoved` / `=destroy` hooks ORC generates for different types. The result is
## heap corruption, seen as store-node segfaults on gcc 11.
##
## GCC PR 122976 (variant of PR 105860), nim-lang/Nim#25001, nim-lang/Nim#26698
## (asks Nim to pass the flag itself, so this file can go). Fixed in newer gcc
## release branches, but older ones, such as gcc 11 on Ubuntu 22.04, are not.
##
## Disabling ICF is the workaround suggested by the GCC developers. `passC` and
## `passL` are global, so every C file of the build gets the flag, whichever
## module is compiled.

{.used.}

when defined(gcc):
  {.passC: "-fno-ipa-icf".}
  {.passL: "-fno-ipa-icf".}
