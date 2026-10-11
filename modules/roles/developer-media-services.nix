_: {
  imports = [ ../services/media-automation.nix ];
  services.fleet.mediaAutomation.enable = true;
  fleet = {
    preparedApplications = {
      enable = true;
      extraSecretPaths = [ "/run/secrets/publication-manager-registry.json" ];
    };
    tailscaleServiceProxy.proxies.deluge-direct = {
      hostname = "deluge-direct.tailbc181.ts.net";
      upstream = "http://127.0.0.1:8112";
      tcpForwards."58846" = "127.0.0.1:58846";
      seedStateFile = "/run/secrets/tailscale-deluge-direct-state.json";
      port = 42100;
    };
    telemetry.enable = true;
  };
}
