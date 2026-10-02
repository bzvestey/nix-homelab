{ pkgs, ... }:
{
  virtualisation = {
    containers.containersConf.settings = {
      containers.log_driver = "journald";
      network.default_rootless_network_cmd = "pasta";
    };
    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
      autoPrune.enable = false;
    };
  };

  systemd = {
    services.podman-prune.enable = false;
    timers.podman-prune.enable = false;

    services.podman-image-prune = {
      description = "Prune Podman images older than 30 days";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.podman}/bin/podman image prune --force --filter until=720h";
      };
    };
    timers.podman-image-prune = {
      description = "Weekly conservative Podman image cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };
  };
}
