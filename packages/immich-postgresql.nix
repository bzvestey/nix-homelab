{ pkgs }:
let
  vector = pkgs.postgresql16Packages.pgvector.overrideAttrs {
    version = "0.8.0";
    src = pkgs.fetchurl {
      url = "https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.0.tar.gz";
      hash = "sha256-hnosMo1JKKWp1vBSzTvHjH1gIoqbkUrTKqPbiOneJ7A=";
    };
  };
  # Upstream's PG16 release avoids importing a second Rust/pgrx toolchain.
  # No index/extension format upgrade is performed during this migration.
  vchord = pkgs.stdenv.mkDerivation {
    pname = "vectorchord";
    version = "0.4.3";
    src = pkgs.fetchurl {
      url = "https://github.com/supervc-stack/VectorChord/releases/download/0.4.3/postgresql-16-vchord_0.4.3_x86_64-linux-gnu.zip";
      hash = "sha256-4Zc1YcKeSxUflhWXBQXj42wkPI9nVrdi4Jd0fFNKlo0=";
    };
    nativeBuildInputs = [
      pkgs.unzip
      pkgs.autoPatchelfHook
    ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    unpackPhase = "unzip $src";
    installPhase = ''
      mkdir -p $out/lib $out/share/postgresql
      cp pkglibdir/vchord.so $out/lib/
      cp -r sharedir/extension $out/share/postgresql/
    '';
    passthru.version = "0.4.3";
    meta.platforms = [ "x86_64-linux" ];
  };
in
pkgs.postgresql_16.withPackages (_: [
  vector
  vchord
])
