{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.lightweightApplications;
  names = [
    "commafeed"
    "donetick"
    "homarr"
    "mailrise"
    "pocket-id"
    "wallos"
  ];
  runtimePath =
    default:
    lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.+";
      inherit default;
      description = "Runtime-only restored application environment/configuration; never a Nix store file.";
    };
in
{
  # Compatibility settings and the bridge are shared; application resources are not.
  options.services.fleet.lightweightApplications = {
    enable = lib.mkEnableOption "source-pinned local lightweight applications";
    applications = lib.mkOption {
      type = lib.types.listOf (lib.types.enum names);
      default = names;
      description = "Applications hosted here; temporary handoffs can select only the services being moved.";
    };
    environmentFiles = lib.genAttrs names (name: runtimePath "/run/secrets/${name}.env");
    donetickConfigFile = runtimePath "/run/secrets/donetick-selfhosted.yaml";
    mailriseConfigFile = runtimePath "/run/secrets/mailrise.conf";
  };
  config =
    lib.mkIf (cfg.enable || lib.any (name: config.services.fleet.${name}.enable or false) names)
      {
        systemd.services.fleet-lightweight-network = {
          description = "DNS-enabled private bridge for lightweight applications";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.podman}/bin/podman network exists fleet-lightweight || \
              ${pkgs.podman}/bin/podman network create --driver bridge fleet-lightweight
          '';
        };
      };
}
