{ pkgs, stdenv, src, version, revision }:

stdenv.mkDerivation {
  pname = "logos-delivery-nimble-deps";
  version = "${version}-${revision}";

  inherit src;

  nativeBuildInputs = with pkgs; [
    jq rsync git nimble cacert moreutils
  ];

  configurePhase = ''
    export XDG_CACHE_HOME=$TMPDIR
    export NIMBLE_DIR=$NIX_BUILD_TOP/nimbledir
    export HOME=$TMPDIR
  '';

  buildPhase = ''
    nimble --version
    nimble --silent --localdeps setup
    nimble --silent --localdeps install -y --depsOnly
  '';

  installPhase = ''
    mkdir -p $out/nimbledeps

    cp nimble.paths $out/nimble.paths

    rsync -ra \
      --prune-empty-dirs \
      --include='*/' \
      --include='*.json' \
      --include='*.nim' \
      --include='*.nimble' \
      --exclude='*' \
      $NIMBLE_DIR/pkgs2 $out/nimbledeps
  '';

  fixupPhase = ''
    # Replace build path with deterministic $out.
    sed "s|$NIMBLE_DIR|./nimbledeps|g" $out/nimble.paths \
      | sort | sponge $out/nimble.paths

    # Nimble does not maintain order of files list.
    for META_FILE in $(find $out -name nimblemeta.json); do
      jq '.metaData.files |= sort' $META_FILE | sponge $META_FILE
    done
  '';

  # Make this a fixed-output derivation to allows internet access for Nimble.
  outputHash = "sha256-OnirsXLj4HMVTbk+b4fcC+1K9MSMJyae6I7JO16WDno=";
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
}
