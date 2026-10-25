{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "nas-telemetry";
  nodes.machine = { nodes, lib, ... }: {
    imports = [ ../modules/fleet/nas-telemetry.nix ];
    fleet.observability.nas = {
      enable = true;
      garageTarget = "nas:18890";
      tokenFile = "/run/garage-token";
      allowedSenders = [ nodes.nas.networking.primaryIPAddress ];
    };
    services.prometheus = {
      enable = true;
      globalConfig.scrape_interval = "1s";
      exporters.graphite.extraFlags = lib.mkForce [
        "--graphite.mapping-strict-match"
        "--graphite.sample-expiry=10s"
      ];
    };
    systemd.tmpfiles.rules = [ "f /run/garage-token 0400 prometheus root - fixture-only" ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];
  };
  nodes.nas = {
    networking.firewall.allowedTCPPorts = [ 18890 ];
    environment.systemPackages = [
      pkgs.netcat-openbsd
      pkgs.curl
    ];
    systemd.services.garage-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "garage-fixture.py" ''
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.headers.get("Authorization") != "Bearer fixture-only":
                    self.send_response(403)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4")
                self.end_headers()
                self.wfile.write(b"cluster_healthy 1\ncluster_available 1\n")
        HTTPServer(("0.0.0.0", 18890), Handler).serve_forever()
      ''}";
    };
  };
  nodes.stranger.environment.systemPackages = [
    pkgs.netcat-openbsd
    pkgs.curl
  ];
  testScript = ''
    start_all()
    machine.wait_for_unit("prometheus.service")
    machine.wait_for_unit("prometheus-graphite-exporter.service")
    nas.wait_for_unit("garage-fixture.service")
    machine.wait_until_succeeds("curl -fsSG --data-urlencode 'query=cluster_healthy{job=\"garage\",host_name=\"nas\"}' localhost:9090/api/v1/query | jq -e '.data.result[0].value[1] == \"1\"'", timeout=30)
    nas.fail("curl -fsS localhost:18890/metrics")
    stranger.fail("nc -z -w 2 machine 9109")
    nas.fail("curl -fsS --max-time 2 http://machine:9108/metrics")
    nas.succeed("(echo truenas.nas.system.cpu.user 23 $(date +%s); echo truenas.nas.system.cpu.idle 71 $(date +%s); echo unrelated.bad 99 $(date +%s)) | nc -N -w 2 machine 9109")
    machine.wait_until_succeeds("curl -fsSG --data-urlencode 'query=truenas_netdata{job=\"truenas\",metric=\"nas.system.cpu.user\"}' localhost:9090/api/v1/query | jq -e '.data.result[0].value[1] == \"23\"'", timeout=30)
    machine.succeed("curl -fsS localhost:9108/metrics | grep 'metric=\"nas.system.cpu.idle\"} 71'")
    machine.fail("curl -fsS localhost:9108/metrics | grep unrelated_bad")
    # Losing the sender must expire its values, not freeze a healthy-looking NAS.
    machine.wait_until_fails("curl -fsS localhost:9108/metrics | grep '^truenas_netdata'", timeout=30)
    machine.succeed("printf wrong > /run/garage-token")
    machine.wait_until_succeeds("curl -fsSG --data-urlencode 'query=up{job=\"garage\"}' localhost:9090/api/v1/query | jq -e '.data.result[0].value[1] == \"0\"'")
  '';
}
