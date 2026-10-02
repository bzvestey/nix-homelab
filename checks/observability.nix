{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "observability";

  nodes.machine = { ... }: {
    imports = [
      ../modules/fleet/backup.nix
      ../modules/roles/observability.nix
    ];
    fleet.observability = {
      enable = true;
      testMode = true;
      scrapeTargets = [ "127.0.0.1:9464" ];
    };
    virtualisation.emptyDiskImages = [ 2048 ];
    environment.systemPackages = with pkgs; [
      curl
      jq
      sqlite
    ];
  };

  testScript = ''
    start_all()
    machine.succeed("mkfs.ext4 -F -L telemetry -O project,quota /dev/vdb")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.fail(f"systemctl is-active {unit}.service")
    machine.succeed("mkdir -p /var/lib/telemetry; systemd-mount --options=prjquota /dev/vdb /var/lib/telemetry")
    machine.wait_until_succeeds("findmnt -M /var/lib/telemetry")
    machine.succeed("systemctl reset-failed; systemctl start prometheus loki tempo grafana otel-gateway")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.wait_for_unit(f"{unit}.service")
    machine.wait_for_open_port(4319)
    metric = '{"resourceMetrics":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"fixture-host"}},{"key":"service.name","value":{"stringValue":"fixture-app"}},{"key":"deployment.environment","value":{"stringValue":"test"}}]},"scopeMetrics":[{"metrics":[{"name":"fleet_fixture_metric","gauge":{"dataPoints":[{"asDouble":7,"timeUnixNano":"1760000000000000000"}]}}]}]}]}'
    machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + metric + "' http://127.0.0.1:4320/v1/metrics")
    machine.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=fleet_fixture_metric' | jq -e '.data.result | length > 0'", timeout=60)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3000/api/health | jq -e '.database == \"ok\"'")
    machine.succeed("curl -fsS http://127.0.0.1:3000/api/datasources | jq -e 'map(.uid) | sort == [\"loki\",\"prometheus\",\"tempo\"]'")
    machine.succeed("curl -fsS 'http://127.0.0.1:3000/api/search?type=dash-db' | jq -e 'map(.uid) | sort == [\"backups\",\"comin\",\"fleet\",\"ingress\",\"postgres\",\"storage\"]'")
    machine.succeed("findmnt -n -o OPTIONS /var/lib/telemetry | grep -Eq '(^|,)prjquota(,|$)'")
    machine.succeed("systemctl stop var-lib-telemetry.mount")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.wait_until_fails(f"systemctl is-active {unit}.service")
  '';
}
