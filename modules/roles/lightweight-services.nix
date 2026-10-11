_: {
  imports = [ ../services/lightweight-applications.nix ];
  services.fleet.lightweightApplications.enable = true;
  fleet = {
    preparedApplications = {
      enable = true;
      extraSecretPaths = [ "/run/secrets/cloudflared-tunnel.json" ];
    };
    tailscaleServiceProxy.proxies.mailrise = {
      hostname = "mailrise.tailbc181.ts.net";
      tcpForwards."25" = "127.0.0.1:8025";
      seedStateFile = "/run/secrets/tailscale-mailrise-state.json";
      port = 42100;
    };
    telemetry.enable = true;
    cloudflared = {
      enable = true;
      routes = map (
        route:
        if route.hostname == "id.minastas.xyz" then
          route // { origin = "http://10.15.4.4:8080"; }
        else
          route
      ) (import ../../lib/public-ingress-routes.nix);
    };
  };
}
