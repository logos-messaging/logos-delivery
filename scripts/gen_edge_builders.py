import re, sys

SRC = "nimbledeps/pkgs2/libp2p-2.0.0-327dc7a0cb7e9d0be3d6083841bd496c4cbc48dc/libp2p/builders.nim"
DST = "wasm-deps/edge_builders.nim"

s = open(SRC).read()

# 1. Rewrite the import block: qualify every module to absolute `libp2p/...`
#    (Nim keys modules by resolved path, so type identity with the real package
#    is preserved), and drop the transports that cannot build for wasm32.
old_imports = s[s.index("import\n  switch,"):s.index("import services/wildcardresolverservice")]
new_imports = """import
  libp2p/switch,
  libp2p/peerid,
  libp2p/peerinfo,
  libp2p/peeraddrpolicy,
  libp2p/stream/connection,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  # wstransport and quictransport dropped: ws pulls autotls/service ->
  # certificate_ffi -> lsquic, quic pulls lsquic + boringssl x86 asm. Neither
  # builds for wasm32, and a browser edge node uses WsBrowserTransport anyway.
  libp2p/transports/[transport, tcptransport, memorytransport],
  libp2p/muxers/[muxer, mplex/mplex, yamux/yamux],
  libp2p/protocols/[identify, secure/secure, secure/noise, rendezvous, kademlia],
  libp2p/protocols/connectivity/[
    autonat/server,
    autonat/client,
    autonat/service,
    autonatv2/server,
    autonatv2/service,
    autonatv2/client,
    relay/relay,
    relay/client,
    relay/rtransport,
  ],
  libp2p/services/[autorelayservice, hpservice, identify_pusher, natservice],
  libp2p/connmanager,
  libp2p/upgrademngrs/muxedupgrade,
  libp2p/observedaddrmanager,
  libp2p/nameresolving/nameresolver,
  libp2p/errors,
  libp2p/utility
"""
s = s.replace(old_imports, new_imports)
s = s.replace("import services/wildcardresolverservice",
              "import libp2p/services/wildcardresolverservice")

# 2. TLSPrivateKey/TLSCertificate/TLSFlags came from the dropped wstransport.
s = s.replace("  TLSPrivateKey, TLSCertificate, TLSFlags, ServerFlags, connmanager.ConnectionLimits,\n",
              "  ServerFlags, connmanager.ConnectionLimits,\n")

# 3. autotls/service is dropped with wstransport, but SwitchBuilder still names
#    its types in field declarations that are NOT behind
#    `when defined(libp2p_autotls_support)`. Stub them: without that define
#    nothing ever constructs one, so the fields stay permanently none.
anchor = "const MemoryAutoAddress* = memorytransport.MemoryAutoAddress"
stub = """# autotls/service is not imported here (it reaches lsquic through
# certificate_ffi). These two types are still named by SwitchBuilder fields that
# sit outside `when defined(libp2p_autotls_support)`, so declare them as opaque
# stubs. libp2p_autotls_support is never defined for the edge build, so nothing
# constructs either one and both fields stay Opt.none forever.
type
  AutotlsService* = ref object
  AutotlsConfig* = ref object

"""
s = s.replace(anchor, stub + anchor)

# 4. Drop the two transport builders whose transports we removed.
for proc_name in ("withWsTransport", "withQuicTransport"):
    m = re.search(r"^proc " + proc_name + r"\*\(.*?^\n", s, re.S | re.M)
    assert m, proc_name
    s = s[:m.start()] + s[m.end():]

note = """# withWsTransport and withQuicTransport are removed with their transports. The
# edge node registers WsBrowserTransport itself and never speaks QUIC.
"""
s = s.replace("proc withMemoryTransport*", note + "proc withMemoryTransport*", 1)

header = """# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Generated override of libp2p/builders for the wasm/edge build.
##
## Identical to libp2p 2.0.0's builders.nim EXCEPT that the QUIC and WS
## transports (and autotls, which WS drags in) are removed -- they reach lsquic
## and boringssl x86 asm, neither of which compiles for wasm32.
##
## It is a separate module rather than a --path override because Nim resolves a
## bare `import libp2p/builders` to the nimble package no matter what --path
## says. Regenerate with scripts/gen_edge_builders.py after a libp2p bump.
"""
s = s.replace("""# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module contains a Switch Building helper.
""", header)

open(DST, "w").write(s)
print("wrote", DST, len(s.splitlines()), "lines")
