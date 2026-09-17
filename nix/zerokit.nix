# zerokit rln built from source; overrides the stale v2.0.2 vendor cargoHash.
# `windows` picks the MinGW build, which zerokit publishes under the platform
# that builds it, as packages.<build>.rln-windows-x86_64 (vacp2p/zerokit#438).
{ zerokit, system, windows ? false }:
zerokit.packages.${system}.${if windows then "rln-windows-x86_64" else "rln"}.overrideAttrs (old: {
  # zerokit#438 added `doCheck = !windows-gnu`, so its own test suite now runs
  # here. `test_pmtree_config_from_str` creates a database at a hardcoded
  # /tmp/pmtree-test-path, which a sandboxed build cannot do (EACCES). We
  # consume the library, not its tests.
  doCheck = false;

  cargoDeps = old.cargoDeps.overrideAttrs (oldCargoDeps: {
    vendorStaging = oldCargoDeps.vendorStaging.overrideAttrs (_: {
      outputHash = "sha256-PNwEdZLgGQPqQDrEK2hsQtSybVfBbD6xn4K47fPFJUU=";
    });
  });
})
