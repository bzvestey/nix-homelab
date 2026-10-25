{ config, lib, ... }:
{
  sops.secrets =
    lib.genAttrs
      [
        "tailscale-auth-key"
        "restic-repository"
        "restic-password"
        "restic-s3-credentials"
      ]
      (name: {
        sopsFile = ../../secrets/hosts/hl-node-00/bootstrap.yaml;
        mode = "0400";
        restartUnits = lib.optional (name == "tailscale-auth-key") "tailscaled-autoconnect.service";
      })
    // {
      garage-metrics-token = {
        sopsFile = ../../secrets/hosts/hl-node-00/telemetry.yaml;
        owner = "prometheus";
        mode = "0400";
        restartUnits = [ "prometheus.service" ];
      };
    };
  fleet = {
    observability.nas.enable = true;
    backup.s3CredentialsFile = config.sops.secrets.restic-s3-credentials.path;
    comin.enableMirror = false;
  };

  systemd.network.networks."20-lan" = {
    matchConfig = {
      Name = "end0";
      MACAddress = "2c:cf:67:72:a7:20";
    };
    address = [ "10.15.4.6/24" ];
    routes = [ { Gateway = "10.15.4.1"; } ];
    networkConfig.DNS = [ "10.15.4.1" ];
  };
}
