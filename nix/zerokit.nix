# zerokit rln built from source; overrides the stale v2.0.2 vendor cargoHash.
{ zerokit, system }:
zerokit.packages.${system}.rln.overrideAttrs (old: {
  cargoDeps = old.cargoDeps.overrideAttrs (oldCargoDeps: {
    vendorStaging = oldCargoDeps.vendorStaging.overrideAttrs (_: {
      outputHash = "sha256-PNwEdZLgGQPqQDrEK2hsQtSybVfBbD6xn4K47fPFJUU=";
    });
  });
})
