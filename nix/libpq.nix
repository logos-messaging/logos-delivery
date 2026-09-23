{ pkgs }:

# db_connector loads libpq at runtime, so Windows artifacts bundle this package
# beside each executable or DLL instead of linking it into their closure.
(pkgs.libpq.override {
  # PostgreSQL 18 links libcurl for OAuth; its MinGW closure does not build.
  curlSupport = false;
}).overrideAttrs (old: {
  # makeWrapper requires a Windows-hosted shell, but libpq does not use it.
  nativeBuildInputs = builtins.filter
    (dep: !(builtins.isAttrs dep && (dep.name or "") == "make-shell-wrapper-hook"))
    old.nativeBuildInputs;

  # This MinGW toolchain uses mcfgthread, while libpq includes pthread.h.
  buildInputs = old.buildInputs ++ [ pkgs.windows.pthreads ];

  # The debug-info split assumes ELF rather than PE artifacts.
  separateDebugInfo = false;
  meta = old.meta // {
    platforms = old.meta.platforms ++ pkgs.lib.platforms.windows;
  };
})
