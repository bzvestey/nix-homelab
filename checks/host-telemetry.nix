{ pkgs }:
let
  image = pkgs.dockerTools.buildImage {
    name = "telemetry-fixture";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "telemetry-fixture-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [
      "/bin/sleep"
      "600"
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "host-telemetry";
  nodes.machine = {
    imports = [
      ../modules/fleet/telemetry-agent.nix
      ../modules/fleet/podman.nix
    ];
    # This VM has no gateway: exercise local metrics during a bounded export
    # failure without depending on production DNS or a minute-long scrape cycle.
    fleet.telemetry = {
      enable = true;
      gatewayEndpoint = "http://127.0.0.1:1";
      retryMaxElapsedTime = "10s";
    };
    services.opentelemetry-collector.settings.receivers.prometheus.config.global.scrape_interval = "1s";
    services.tailscale.enable = true;
    virtualisation.oci-containers = {
      backend = "podman";
      containers = builtins.listToAttrs (
        map
          (name: {
            inherit name;
            value = {
              image = "telemetry-fixture:latest";
              imageFile = image;
              autoStart = false;
            };
          })
          [
            "running"
            "stopped"
            "absent"
          ]
      );
    };
    environment.systemPackages = [ pkgs.curl ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("opentelemetry-collector.service")
    machine.succeed("systemctl start podman-running; podman create --name stopped telemetry-fixture:latest")
    machine.succeed("systemctl start podman-telemetry.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep -E '^fleet_podman_container_running\\{.*container=\"running\".* 1$'", timeout=90)
    machine.succeed("grep -Fx 'fleet_podman_container_running{container=\"stopped\"} 0' /var/lib/node_exporter/textfile_collector/podman.prom; grep -Fx 'fleet_podman_container_present{container=\"stopped\"} 1' /var/lib/node_exporter/textfile_collector/podman.prom; grep -Fx 'fleet_podman_container_present{container=\"absent\"} 0' /var/lib/node_exporter/textfile_collector/podman.prom")
    machine.succeed("podman stop running; systemctl start podman-telemetry.service; grep -Fx 'fleet_podman_container_running{container=\"running\"} 0' /var/lib/node_exporter/textfile_collector/podman.prom")
    # No enrollment in this VM. A real LocalAPI read must still emit typed
    # collection status all the way through the node -> OTel -> Prometheus path.
    machine.wait_for_unit("tailscaled.service")
    machine.succeed("systemctl start tailscale-telemetry.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep '^tailscale_status_collection_success{'", timeout=90)
    # Real exporter on a VM with no SMART-capable disk: missing device data is
    # legitimate, but the exporter must be reachable without opening the LAN.
    machine.wait_for_unit("prometheus-smartctl-exporter.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep '^smartctl_exporter_build_info'", timeout=90)
    machine.succeed("ss -lnt | grep '127.0.0.1:9633'")
  '';
}
