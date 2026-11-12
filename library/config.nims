# liblogosdelivery's default configuration: what the library is and what its
# code needs. The caller's flags come later and win. The target, toolchain,
# CPU baseline, policy (--mm, --opt, release, log level), outputs and link
# inputs (librln, LeopardCmakeFlags for a cross build) come from the caller.

switch("path", thisDir() & "/..")
--threads:on
# peer_manager deep-copies its exclusive peers, which ARC/ORC compile only with this.
--deepcopy:on
--noMain
--header
switch("nimMainPrefix", "liblogosdelivery")

# The public headers include generated/logosdelivery.h.
# `-d:ffiSrcPath` is required: without it nim-ffi derives the path with
# `relativePath`, which needs `getcwd` at compile time and fails to build.
switch("define", "ffiGenBindings")
switch("define", "targetLang=c")
switch("define", "ffiSrcPath=../liblogosdelivery.nim")
when not defined(ffiOutputDir):
  switch("define", "ffiOutputDir=" & nimcacheDir() & "/generated")

switch("define", "libp2p_mix_experimental_exit_is_dest")
switch("define", "discv5_protocol_id=d5waku")
switch("define", "libp2p_quic_support")
# Makes the `logLevel` the host passes in the create config take effect.
switch("define", "chronicles_runtime_filtering=on")
# Desktop: lets the host pick `log-format` and `log-output`. Mobile keeps
# its own sink setup.
when not defined(android) and not defined(ios):
  switch("define", "chronicles_sinks=textlines,json")
  switch("define", "chronicles_default_output_device=dynamic")
# Metric collection, and for heap-usage-by-instance-type metrics and object
# base-type strings.
switch("define", "metrics")
switch("define", "nimTypeNames")
# https://github.com/status-im/nim-confutils/issues/9
switch("define", "nimOldCaseObjects")

switch("warning", "CaseTransition:off")
# https://github.com/nim-lang/RFCs/issues/230
switch("warning", "ObservableStores:off")
switch("warning", "LockLevel:off")

when defined(macosx):
  # Apple Clang 16+ makes -Wincompatible-function-pointer-types an error. It
  # fires on chronos' PEM callback passed to bearssl (chronos/streams/tlsstream.nim),
  # which only reads the buffer, so demote it back to a warning.
  switch("passC", "-Wno-error=incompatible-function-pointer-types")

when defined(android):
  switch("define", "androidNDK")
  switch("define", "chronosEventEngine=epoll")
  switch("define", "chronicles_sinks=textlines[dynamic]")
  switch("passL", "-llog")
  # Leopard-RS is C++, and the NDK's C driver links no C++ runtime by itself.
  switch("passL", "-lc++_static -lc++abi")
