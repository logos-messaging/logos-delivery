## Writes the results of the run as JUnit XML next to the test binary.
## Import it first: tests run while their modules initialize.

{.used.}

import std/[os, streams], unittest2

addOutputFormatter(
  newJUnitOutputFormatter(
    openFileStream(getAppFilename().changeFileExt("xml"), fmWrite)
  )
)
