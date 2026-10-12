{ lib, ... }:
{
  sops.secrets =
    lib.genAttrs
      [
        "tailscale-auth-key"
        "restic-repository"
        "restic-password"
        "restic-s3-credentials"
      ]
      (_: {
        sopsFile = ../../secrets/hosts/hl-node-01/bootstrap.yaml;
        mode = "0400";
        restartUnits = [ ];
      });
  fleet.preparedApplications.existingSecretPaths = [
    "/run/secrets/tailscale-auth-key"
    "/run/secrets/restic-repository"
    "/run/secrets/restic-password"
    "/run/secrets/restic-s3-credentials"
  ];
  fleet.preparedApplications.secretsFile = ../../secrets/hosts/hl-node-01/applications.yaml;
  fleet.comin.enableMirror = false;
  fleet.ingress.lanInterface = "end0";
  systemd.network.networks."20-lan" = {
    matchConfig = {
      Name = "end0";
      MACAddress = "2c:cf:67:ed:27:ed";
    };
    address = [ "10.15.4.4/24" ];
    routes = [ { Gateway = "10.15.4.1"; } ];
    networkConfig.DNS = [ "10.15.4.1" ];
  };
}
