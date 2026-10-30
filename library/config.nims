# An embedded build passes --skipParentCfg, which also skips this package's root config.
when defined(lddEmbedded):
  # The root config's Nimble block reads nimble.paths from thisDir(), which is library/ here.
  when withDir(thisDir(), system.fileExists("nimble.paths")):
    {.error: "remove library/nimble.paths: this build takes its --paths only from NIM_PARAMS".}
  include "../config.nims"
