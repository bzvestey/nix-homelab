{ pkgs }:
# Exact upstream 2.5.8 release; retain nixpkgs' native sqlite packaging.
pkgs.uptime-kuma.overrideAttrs (
  final: _: {
    version = "2.5.8";
    src = pkgs.fetchFromGitHub {
      owner = "louislam";
      repo = "uptime-kuma";
      rev = "0bd417b981d7dd4e7a0ecaa5afcd90c274d74eca";
      hash = "sha256-9Sq35o1ecsNR28ooZb2m2phFT5CXe930FK6JLb4eMkc=";
    };
    npmDepsHash = "sha256-aF5HXuPyIn1HZ7gWiJV1ABfJNkTnNqfE5rdG5Dccq/o=";
    npmDeps = pkgs.fetchNpmDeps {
      inherit (final) src;
      hash = final.npmDepsHash;
    };
  }
)
