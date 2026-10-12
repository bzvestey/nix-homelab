{ lib, ... }:
{
  options.services.fleet.remainingApplications = {
    enable = lib.mkEnableOption "restored node-02 prerequisites (never enabled automatically)";
    registryAuthFile = lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.*";
      default = "/run/secrets/remaining-applications-registry.json";
      description = "Runtime Podman auth JSON for ghcr.io and atcr.io; never copied into the store.";
    };
  };
}
