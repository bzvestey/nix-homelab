{ ... }:
{
  imports = [
    ../../modules/fleet/base.nix
    ../../modules/fleet/networking.nix
    ../../modules/fleet/comin.nix
    ../../modules/fleet/telemetry-agent.nix
    ../../modules/roles/observability.nix
  ];
  fleet = {
    telemetry.enable = true;
    observability.enable = true;
    cloudflared = {
      enable = true;
      routes = import ../../lib/public-ingress-routes.nix;
    };
  };
  sops.secrets."cloudflared-tunnel.json".sopsFile = ../../secrets/pi-connectors/cloudflared.yaml;
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
