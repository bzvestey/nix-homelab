{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "telemetry-agent";

  nodes.agent =
    {
      config,
      lib,
      options,
      ...
    }:
    {
      imports = [
        ../modules/fleet/telemetry-agent.nix
        {
          options.services.comin.enable = lib.mkEnableOption "test comin fixture";
        }
      ];
      networking.hostName = "telemetry-test";
      services.comin.enable = true;
      fleet.telemetry = {
        enable = true;
        gatewayEndpoint = "http://gateway:4318";
        retryMaxElapsedTime = "10s";
        revision = "test-revision";
        localPrometheusTargets.fixture = "127.0.0.1:18080";
      };
      systemd.services = {
        fixture = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 18080 --directory /var/lib/fixture";
          preStart = ''
            mkdir -p /var/lib/fixture
            cat > /var/lib/fixture/metrics <<'EOF'
            # TYPE fleet_fixture_total counter
            fleet_fixture_total{safe_label="SAFE_VALUE"} 7
            EOF
          '';
        };
        comin-fixture = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 4243 --directory /var/lib/comin-fixture";
          preStart = ''
            mkdir -p /var/lib/comin-fixture
            cat > /var/lib/comin-fixture/metrics <<'EOF'
            # TYPE comin_build_total counter
            comin_build_total 11
            EOF
          '';
        };
        node-textfile-fixture = {
          wantedBy = [ "multi-user.target" ];
          before = [ "prometheus-node-exporter.service" ];
          serviceConfig.Type = "oneshot";
          script = ''
            mkdir -p /var/lib/node_exporter/textfile_collector
            cat > /var/lib/node_exporter/textfile_collector/backup.prom <<'EOF'
            # TYPE backup_last_success_timestamp_seconds gauge
            backup_last_success_timestamp_seconds 12345
            EOF
          '';
        };
        unrelated-application = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };
      environment.systemPackages = [ pkgs.curl ];

      assertions = [
        {
          assertion = options.fleet.telemetry.gatewayEndpoint.default == "http://observability:4320";
          message = "the telemetry gateway default must use the observability role alias";
        }
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
        {
          assertion = !(config.fleet.telemetry ? extraCollectorSettings);
          message = "collector settings must not be replaceable through an unrestricted option";
        }
        {
          assertion =
            config.services.opentelemetry-collector.settings.service.pipelines.metrics.processors == [
              "memory_limiter"
              "transform/normalize"
              "batch"
            ];
          message = "final metrics pipeline must retain mandatory processors";
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
    agent.wait_until_succeeds("metrics=$(curl -fsS http://127.0.0.1:9464/metrics); grep -q fleet_fixture_total <<<\"$metrics\" && grep -q comin_build_total <<<\"$metrics\" && grep -q backup_last_success_timestamp_seconds <<<\"$metrics\"")
    metrics = agent.succeed("curl -fsS http://127.0.0.1:9464/metrics")
    assert "system_cpu" in metrics
    assert "otelcol_" in metrics
    assert 'safe_label="SAFE_VALUE"' in metrics
    assert "comin_build_total" in metrics
    assert "backup_last_success_timestamp_seconds" in metrics
    assert metrics.count('comin_build_total{') == 1
    comin_metric = next(line for line in metrics.splitlines() if line.startswith("comin_build_total{"))
    for label in ["deployment_environment", "deployment_revision", "host_name", "service_name"]:
        assert comin_metric.count(label + "=") == 1
    agent.succeed("systemctl is-active unrelated-application.service")
    for prop in ["After", "Requires", "Wants", "BindsTo"]:
        value = agent.succeed(f"systemctl show unrelated-application.service -p {prop} --value")
        assert "opentelemetry-collector" not in value

    trace = '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"custom-service"}},{"key":"auth_token","value":{"stringValue":"AUTH_SECRET"}},{"key":"http.request.header.authorization","value":{"stringValue":"HEADER_SECRET"}},{"key":"benign","value":{"stringValue":"BENIGN_SENTINEL"}}]},"scopeSpans":[{"spans":[{"traceId":"5B8EFFF798038103D269B633813FC60C","spanId":"EEE19B7EC3C1B174","name":"fixture-span","kind":1,"startTimeUnixNano":"1544712660000000000","endTimeUnixNano":"1544712661000000000","attributes":[{"key":"session.cookie","value":{"stringValue":"COOKIE_SECRET"}},{"key":"client-api-key","value":{"stringValue":"API_SECRET"}}]}]}]}]}'
    agent.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + trace + "' http://127.0.0.1:4318/v1/traces")
    metric = '{"resourceMetrics":[{"resource":{"attributes":[{"key":"db.password","value":{"stringValue":"DB_SECRET"}},{"key":"benign.resource","value":{"stringValue":"METRIC_BENIGN"}}]},"scopeMetrics":[{"metrics":[{"name":"qualified_key_fixture","gauge":{"dataPoints":[{"asDouble":3,"timeUnixNano":"1544712661000000000","attributes":[{"key":"Api_Key","value":{"stringValue":"METRIC_API_SECRET"}},{"key":"safe_label","value":{"stringValue":"SAFE_METRIC_VALUE"}}]}]}}]}]}]}'
    agent.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + metric + "' http://127.0.0.1:4318/v1/metrics")
    agent.wait_until_succeeds("curl -fsS http://127.0.0.1:9464/metrics | grep qualified_key_fixture")
    metrics = agent.succeed("curl -fsS http://127.0.0.1:9464/metrics")
    assert "SAFE_METRIC_VALUE" in metrics
    assert "METRIC_BENIGN" in metrics
    assert "DB_SECRET" not in metrics
    assert "METRIC_API_SECRET" not in metrics
    agent.succeed("systemd-cat -t ordinary-fixture echo JOURNAL_BENIGN")
    agent.succeed("systemd-cat -t podman -p info echo PODMAN_JOURNAL_FIXTURE")
    gateway.wait_until_succeeds("grep -q fixture-span /var/lib/opentelemetry-collector/gateway.json")
    gateway.wait_until_succeeds("grep -q qualified_key_fixture /var/lib/opentelemetry-collector/gateway.json")
    exported = gateway.succeed("cat /var/lib/opentelemetry-collector/gateway.json")
    assert "custom-service" in exported
    assert "telemetry-test" in exported
    assert "homelab" in exported
    assert "test-revision" in exported
    assert "BENIGN_SENTINEL" in exported
    assert "METRIC_BENIGN" in exported
    assert "SAFE_METRIC_VALUE" in exported
    for secret in ["AUTH_SECRET", "HEADER_SECRET", "COOKIE_SECRET", "API_SECRET", "DB_SECRET", "METRIC_API_SECRET"]:
        assert secret not in exported
    gateway.wait_until_succeeds("grep -q JOURNAL_BENIGN /var/lib/opentelemetry-collector/gateway.json")
    gateway.wait_until_succeeds("grep -q PODMAN_JOURNAL_FIXTURE /var/lib/opentelemetry-collector/gateway.json")

    agent.wait_until_succeeds("test -n \"$(find -L /var/lib/opentelemetry-collector -type f -print -quit)\"", timeout=30)
    state = agent.succeed("find -L /var/lib/opentelemetry-collector -type f -printf '%P\\n'").splitlines()
    assert state
    assert all(path.startswith("checkpoints/") for path in state)

    gateway.succeed("systemctl stop opentelemetry-collector.service")
    agent.succeed("systemd-cat -t outage-fixture echo JOURNAL_DURING_OUTAGE")
    agent.wait_until_succeeds("journalctl -u opentelemetry-collector.service --since '-30 seconds' --grep='Exporting failed. Will retry' --quiet", timeout=30)
    agent.wait_until_succeeds("curl -fsS http://127.0.0.1:8888/metrics | awk '/^otelcol_exporter_send_failed_log_records{/ && /exporter=/ && $NF > 0 { found=1 } END { exit !found }'", timeout=30)
    failed = agent.succeed("curl -fsS http://127.0.0.1:8888/metrics | grep '^otelcol_exporter_send_failed_log_records{'")
    assert 'exporter="otlphttp"' in failed
    agent.succeed("systemctl is-active unrelated-application.service")
    retry_events_before = int(agent.succeed("journalctl -u opentelemetry-collector.service --grep='Exporting failed. Will retry' --output=cat | wc -l").strip())
    agent.succeed("systemd-cat -t recovery-fixture echo JOURNAL_AFTER_RECOVERY")
    agent.wait_until_succeeds("test $(journalctl -u opentelemetry-collector.service --grep='Exporting failed. Will retry' --output=cat | wc -l) -gt " + str(retry_events_before), timeout=8)
    gateway.succeed("systemctl start opentelemetry-collector.service")
    gateway.wait_until_succeeds("grep -q JOURNAL_AFTER_RECOVERY /var/lib/opentelemetry-collector/gateway.json", timeout=10)

    before = gateway.succeed("grep -c JOURNAL_AFTER_RECOVERY /var/lib/opentelemetry-collector/gateway.json").strip()
    agent.succeed("systemctl restart opentelemetry-collector.service")
    agent.wait_for_unit("opentelemetry-collector.service")
    agent.succeed("systemd-cat -t checkpoint-fixture echo JOURNAL_AFTER_RESTART")
    gateway.wait_until_succeeds("grep -q JOURNAL_AFTER_RESTART /var/lib/opentelemetry-collector/gateway.json")
    after = gateway.succeed("grep -c JOURNAL_AFTER_RECOVERY /var/lib/opentelemetry-collector/gateway.json").strip()
    assert before == after
  '';
}
