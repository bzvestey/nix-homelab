{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "telemetry-agent";

  nodes.agent =
    { config, lib, ... }:
    {
      imports = [ ../modules/fleet/telemetry-agent.nix ];
      networking.hostName = "telemetry-test";
      fleet.telemetry = {
        enable = true;
        gatewayEndpoint = "http://gateway:4318";
        revision = "test-revision";
        localPrometheusTargets.fixture = "127.0.0.1:18080";
      };
      systemd.services.fixture = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 18080 --directory /var/lib/fixture";
        preStart = ''
          mkdir -p /var/lib/fixture
          cat > /var/lib/fixture/metrics <<'EOF'
          # TYPE fleet_fixture_total counter
          fleet_fixture_total 7
          EOF
        '';
      };
      systemd.services.unrelated-application = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
      environment.systemPackages = [ pkgs.curl ];

      assertions = [
        {
          assertion =
            !(lib.elem "opentelemetry-collector.service" config.systemd.services.unrelated-application.after);
          message = "applications must not depend on telemetry";
        }
        {
          assertion =
            config.services.opentelemetry-collector.settings.exporters.otlphttp.endpoint
            == "http://gateway:4318";
          message = "agent must use the configured gateway";
        }
        {
          assertion =
            config.services.opentelemetry-collector.settings.exporters.otlphttp.sending_queue.enabled == false;
          message = "persistent or memory sending queues are forbidden";
        }
      ];
    };

  nodes.gateway = {
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      settings = {
        receivers.otlp.protocols.http.endpoint = "0.0.0.0:4318";
        exporters.file = {
          path = "/var/lib/opentelemetry-collector/gateway.json";
          flush_interval = "1s";
        };
        service.pipelines = {
          metrics = {
            receivers = [ "otlp" ];
            exporters = [ "file" ];
          };
          logs = {
            receivers = [ "otlp" ];
            exporters = [ "file" ];
          };
          traces = {
            receivers = [ "otlp" ];
            exporters = [ "file" ];
          };
        };
      };
    };
    networking.firewall.allowedTCPPorts = [ 4318 ];
  };

  testScript = ''
    start_all()
    gateway.wait_for_unit("opentelemetry-collector.service")
    agent.wait_for_unit("opentelemetry-collector.service")
    agent.wait_for_unit("unrelated-application.service")
    agent.wait_for_open_port(9464)
    agent.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep fleet_fixture_total")
    metrics = agent.succeed("curl -fsS http://127.0.0.1:9464/metrics")
    assert "system_cpu" in metrics
    assert "otelcol_" in metrics
    agent.succeed("systemctl is-active unrelated-application.service")

    trace = '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"custom-service"}},{"key":"ApiKey","value":{"stringValue":"SECRET_SENTINEL"}},{"key":"benign","value":{"stringValue":"BENIGN_SENTINEL"}}]},"scopeSpans":[{"spans":[{"traceId":"5B8EFFF798038103D269B633813FC60C","spanId":"EEE19B7EC3C1B174","name":"fixture-span","kind":1,"startTimeUnixNano":"1544712660000000000","endTimeUnixNano":"1544712661000000000"}]}]}]}'
    agent.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + trace + "' http://127.0.0.1:4318/v1/traces")
    agent.succeed("systemd-cat -t ordinary-fixture echo JOURNAL_BENIGN")
    agent.succeed("systemd-cat -t podman -p info echo PODMAN_JOURNAL_FIXTURE")
    gateway.wait_until_succeeds("grep -q fixture-span /var/lib/opentelemetry-collector/gateway.json")
    exported = gateway.succeed("cat /var/lib/opentelemetry-collector/gateway.json")
    assert "custom-service" in exported
    assert "telemetry-test" in exported
    assert "homelab" in exported
    assert "test-revision" in exported
    assert "BENIGN_SENTINEL" in exported
    assert "SECRET_SENTINEL" not in exported
    gateway.wait_until_succeeds("grep -q JOURNAL_BENIGN /var/lib/opentelemetry-collector/gateway.json")
    gateway.wait_until_succeeds("grep -q PODMAN_JOURNAL_FIXTURE /var/lib/opentelemetry-collector/gateway.json")

    gateway.succeed("systemctl stop opentelemetry-collector.service")
    agent.succeed("systemd-cat -t outage-fixture echo JOURNAL_AFTER_RECOVERY")
    agent.succeed("systemctl is-active unrelated-application.service")
    gateway.succeed("systemctl start opentelemetry-collector.service")
    gateway.wait_until_succeeds("grep -q JOURNAL_AFTER_RECOVERY /var/lib/opentelemetry-collector/gateway.json")

    before = gateway.succeed("grep -c JOURNAL_AFTER_RECOVERY /var/lib/opentelemetry-collector/gateway.json").strip()
    agent.succeed("systemctl restart opentelemetry-collector.service")
    agent.wait_for_unit("opentelemetry-collector.service")
    agent.succeed("systemd-cat -t checkpoint-fixture echo JOURNAL_AFTER_RESTART")
    gateway.wait_until_succeeds("grep -q JOURNAL_AFTER_RESTART /var/lib/opentelemetry-collector/gateway.json")
    after = gateway.succeed("grep -c JOURNAL_AFTER_RECOVERY /var/lib/opentelemetry-collector/gateway.json").strip()
    assert before == after
  '';
}
