#!/usr/bin/env bash
# Fails when the shared library exports OpenSSL-named symbols.
#
# BoringSSL is compiled in with hidden visibility. If its SSL_/EVP_/X509_/ASN1_
# symbols leak into the dynamic symbol table, a host process that already loaded
# OpenSSL (Node.js, LD_PRELOAD=libssl.so.3, ...) gets its calls bound to the
# wrong library, which crashed QUIC in setupSSLContext (#4085).
#
#   scripts/check_lib_exports.sh build/liblogosdelivery.so
set -euo pipefail

lib="${1:?usage: $0 <shared library>}"

case "$(uname -s)" in
  Darwin) exports="$(nm -gU "$lib" | awk '{print $NF}' | sed 's/^_//')" ;;
  *) exports="$(nm -D --defined-only "$lib" | awk '{print $NF}')" ;;
esac

leaked="$(grep -E '^(SSL|EVP|X509|ASN1)_' <<<"$exports" || true)"
if [[ -n "$leaked" ]]; then
  echo "$lib exports $(wc -l <<<"$leaked" | tr -d ' ') OpenSSL-named symbols, e.g.:" >&2
  head -5 <<<"$leaked" >&2
  exit 1
fi
echo "$lib: no OpenSSL-named symbols exported"
