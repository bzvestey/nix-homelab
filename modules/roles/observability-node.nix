{ ... }:
{
  imports = [ ./observability.nix ];
  fleet = {
    telemetry.enable = true;
    observability.enable = true;
    cloudflared = {
      enable = true;
      routes = import ../../lib/public-ingress-routes.nix;
    };
  };
  sops.secrets."cloudflared-tunnel.json".sopsFile = ../../secrets/pi-connectors/cloudflared.yaml;
}
