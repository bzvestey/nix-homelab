{ pkgs }:
# Exact release commit; nixpkgs' 2.5.5 recipe supplies native sqlite packaging.
pkgs.uptime-kuma.overrideAttrs (
  final: _: {
    version = "2.5.6";
    src = pkgs.fetchFromGitHub {
      owner = "louislam";
      repo = "uptime-kuma";
      rev = "7ca4a3debd76443d8452da95d4040200a1479af4";
      hash = "sha256-GmOwS13t8OcKMBeIUH3dE6WLgWRiIS3N619XvWvmIu8=";
    };
    npmDepsHash = "sha256-u9pFRM3tLVK4MZaE+ytZN8tURpb/aRDrgNjVkNpnUUA=";
    npmDeps = pkgs.fetchNpmDeps {
      inherit (final) src;
      hash = final.npmDepsHash;
    };
  }
)
