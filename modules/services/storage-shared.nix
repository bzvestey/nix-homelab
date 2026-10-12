{ config, lib, ... }:
let
  cfg = config.services.fleet.storageApplications;
  names = [
    "jellyfin"
    "kavita"
    "vikunja"
  ];
  runtimeOption =
    name:
    lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.*";
      default = "/run/secrets/${name}";
      description = "Enrolled runtime file; never place credentials in the Nix store.";
    };
in
{
  options.services.fleet.storageApplications = {
    enable = lib.mkEnableOption "source-compatible storage applications";
    jellyfinEnvironmentFile = runtimeOption "jellyfin.env";
    kavitaEnvironmentFile = runtimeOption "kavita.env";
    vikunjaEnvironmentFile = runtimeOption "vikunja.env";
    vikunjaConfigFile = runtimeOption "vikunja-config.yml";
  };
  config =
    lib.mkIf (cfg.enable || lib.any (name: config.services.fleet.${name}.enable or false) names)
      {
        users.groups.storage-apps.gid = 1000;
        users.users.storage-apps = {
          isSystemUser = true;
          uid = 1000;
          group = "storage-apps";
          extraGroups = [
            "video"
            "render"
          ];
        };
        hardware.graphics.enable = true;
      };
}
