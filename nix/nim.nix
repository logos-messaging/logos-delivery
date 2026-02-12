{ lib
, stdenv
, fetchurl
, pkgconfig
, gcc }:

stdenv.mkDerivation rec {
  pname = "nim";
  version = "2.2.6";

  src = fetchurl {
    url = "https://github.com/nim-lang/Nim/archive/refs/tags/v2.2.6.tar.gz";
    sha256 = "0q27fxky7xh0r5kyldl02dm5rs5pkz96g2sgfgwpxy4v86b6qlpp"; # computed via nix-prefetch-url
  };

  nativeBuildInputs = [ gcc pkgconfig ];

  buildPhase = ''
    cd $src
    sh build.sh
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp bin/nim $out/bin/
  '';

  meta = with lib; {
    description = "Official Nim compiler 2.2.6";
    homepage = "https://nim-lang.org";
    license = lib.licenses.mit;
  };
}
