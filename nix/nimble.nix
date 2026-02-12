{ lib
, stdenv
, fetchgit
, pkg-config
, pkgs
, nimPinned
}:

stdenv.mkDerivation rec {
  pname = "my-nimble";
  version = "0.99.0-9e488db"; # your own human version

  src = fetchgit {
    url = "https://github.com/nim-lang/nimble.git";
    rev = "9e488db1233004d6fb42923739f8b8cb12485f30";
    # computed hash of the Git snapshot:
    sha256 = "sha256-MhLkXgnwsCtbPbxo3J3e+//6BMsTEgvDZlbPY/ONEeE=";
  };

  nativeBuildInputs = [ pkg-config nim pkgs.openssl ];

  configurePhase = ''
    export HOME=$TMPDIR

    mkdir -p $NIMBLE_DIR/pkgs2/nim-2.2.6/bin
    cp -r ${nimPinned}/bin/* $NIMBLE_DIR/pkgs2/nim-2.2.6/bin/
  '';

  buildPhase = ''
    echo "Copying source to build directory..."
    cp -r $src/* .  # Copy into $PWD

    echo "Compiling nimble..."
    nim c -d:release src/nimble.nim
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp src/nimble $out/bin/
  '';

  meta = with lib; {
    description = "Nim package manager from specific commit";
    homepage = "https://github.com/nim-lang/nimble";
    license = licenses.mit;
    maintainers = [];
  };
}
