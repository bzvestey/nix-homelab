_: {
  fleet = {
    telemetry.enable = true;
    cloudflared = {
      enable = true;
      routes = import ../../lib/public-ingress-routes.nix;
    };
  };
}
