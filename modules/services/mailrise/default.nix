{ config, lib, ... }:
let
  cfg = config.services.fleet.mailrise;
  group = config.services.fleet.lightweightApplications;
in
{
  imports = [ ../lightweight-shared.nix ];
  options.services.fleet.mailrise.enable = lib.mkEnableOption "Mailrise";
  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers.mailrise = {
        image = "docker.io/yoryan/mailrise@sha256:0b8b1ce3447c83b625c9e8896cd9c3db0205590f92ce4d4adaae69729830f52b";
        environmentFiles = [ group.environmentFiles.mailrise ];
        environment.TZ = "America/Los_Angeles";
        volumes = [ "${group.mailriseConfigFile}:/etc/mailrise.conf:ro" ];
        ports = [ "127.0.0.1:8025:8025" ];
        extraOptions = [ "--network=fleet-lightweight" ];
        cmd = [
          "--very-verbose"
          "/etc/mailrise.conf"
        ];
      };
    };
    systemd.services.podman-mailrise = {
      requires = [ "fleet-lightweight-network.service" ];
      after = [ "fleet-lightweight-network.service" ];
      unitConfig.ConditionPathExists = [
        group.environmentFiles.mailrise
        group.mailriseConfigFile
      ];
    };
  };
}
