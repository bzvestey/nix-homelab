{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "observability";

  nodes.machine = { config, ... }: {
    imports = [
      ../modules/fleet/backup.nix
      ../modules/roles/observability.nix
    ];
    fleet.observability = {
      enable = true;
      testMode = true;
      scrapeTargets = [ "127.0.0.1:9464" ];
    };
    fleet.backup = {
      repositoryFile = "/run/observability-test/restic-repository";
      passwordFile = "/run/observability-test/restic-password";
    };
    virtualisation.emptyDiskImages = [ 2048 ];
    environment.systemPackages = with pkgs; [
      curl
      jq
      restic
      sqlite
    ];
    assertions = [
      {
        assertion =
          config.fleet.observability.storage.totalBudgetBytes
          <= config.fleet.observability.storage.minimumFilesystemBytes * 85 / 100;
        message = "telemetry budgets exceed reserved SSD capacity";
      }
      {
        assertion = !config.services.grafana.settings."auth.anonymous".enabled;
        message = "Grafana anonymous access must be disabled";
      }
      {
        assertion = config.services.grafana.settings.security.admin_password != "admin";
        message = "Grafana must not use its default administrator password";
      }
    ];
  };

  testScript = ''
    import hashlib

    start_all()
    machine.succeed("mkfs.ext4 -F -L telemetry -O project,quota /dev/vdb")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.fail(f"systemctl is-active {unit}.service")
    machine.wait_for_unit("systemd-tmpfiles-setup.service")
    machine.succeed("mkdir -p /var/lib/telemetry; test -z \"$(find /var/lib/telemetry -mindepth 1 -print -quit)\"")
    machine.succeed("mkdir -p /var/lib/telemetry; systemd-mount --options=prjquota /dev/vdb /var/lib/telemetry")
    machine.wait_until_succeeds("findmnt -M /var/lib/telemetry")
    machine.succeed("systemctl reset-failed; systemctl start prometheus loki tempo grafana otel-gateway")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.wait_for_unit(f"{unit}.service")
    machine.wait_for_open_port(4319)
    for project, directory in [(1001, "prometheus"), (1002, "loki"), (1003, "tempo"), (1004, "grafana")]:
        machine.succeed(f"touch /var/lib/telemetry/{directory}/quota-child; test $(${pkgs.e2fsprogs}/bin/lsattr -p /var/lib/telemetry/{directory}/quota-child | awk '{{print $1}}') = {project}")
        machine.succeed(f"${pkgs.e2fsprogs}/bin/lsattr -d /var/lib/telemetry/{directory} | grep -q P")
    now = machine.succeed("date +%s%N").strip()
    metric = '{"resourceMetrics":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"fixture-host"}},{"key":"service.name","value":{"stringValue":"fixture-app"}},{"key":"deployment.environment","value":{"stringValue":"test"}}]},"scopeMetrics":[{"metrics":[{"name":"fleet_fixture_metric","gauge":{"dataPoints":[{"asDouble":7,"timeUnixNano":"' + now + '"}]}}]}]}]}'
    machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + metric + "' http://127.0.0.1:4320/v1/metrics")
    machine.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=fleet_fixture_metric' | jq -e '.data.result | length > 0'", timeout=60)
    now = machine.succeed("date +%s%N").strip()
    log_payload = '{"resourceLogs":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"fixture-host"}},{"key":"service.name","value":{"stringValue":"fixture-app"}},{"key":"deployment.environment","value":{"stringValue":"test"}},{"key":"cloud.token","value":{"stringValue":"RESOURCE-SECRET"}},{"key":"container.id","value":{"stringValue":"high-cardinality"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"' + now + '","body":{"stringValue":"benign gateway log"},"attributes":[{"key":"HTTP.Request.Header.Authorization","value":{"stringValue":"SIGNAL-SECRET"}},{"key":"request.id","value":{"stringValue":"unbounded-label"}}]}]}]}]}'
    machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + log_payload + "' http://127.0.0.1:4320/v1/logs")
    machine.wait_until_succeeds("curl -GfsS --data-urlencode 'query={service_name=\"fixture-app\"} |= \"benign gateway log\"' http://127.0.0.1:3100/loki/api/v1/query_range | jq -e '.data.result | length == 1'", timeout=60)
    machine.succeed("curl -fsS http://127.0.0.1:3100/loki/api/v1/labels | jq -e '.data as $d | ([\"deployment_environment\",\"host_name\",\"service_name\"] - $d | length == 0) and ([$d[] | select(test(\"(?i)(password|token|secret|authorization|cookie|api_?key|trace_?id|span_?id|container_?id|path|revision|request_?id)\"))] | length == 0)' ")
    machine.succeed("! curl -GfsS --data-urlencode 'query={service_name=\"fixture-app\"}' http://127.0.0.1:3100/loki/api/v1/query_range | grep -E 'RESOURCE-SECRET|SIGNAL-SECRET|high-cardinality|unbounded-label'")
    def send_trace(trace_id, span_id, name, status, duration):
        start = int(machine.succeed("date +%s%N").strip())
        trace = '{"resourceSpans":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"fixture-host"}},{"key":"service.name","value":{"stringValue":"fixture-app"}},{"key":"deployment.environment","value":{"stringValue":"test"}},{"key":"db.password","value":{"stringValue":"TRACE-SECRET"}}]},"scopeSpans":[{"spans":[{"traceId":"' + trace_id + '","spanId":"' + span_id + '","name":"' + name + '","kind":2,"startTimeUnixNano":"' + str(start) + '","endTimeUnixNano":"' + str(start + duration) + '","status":{"code":' + str(status) + '},"attributes":[{"key":"HTTP.Authorization.Token","value":{"stringValue":"SPAN-SECRET"}}]}]}]}]}'
        machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + trace + "' http://127.0.0.1:4320/v1/traces")
    send_trace("11111111111111111111111111111111", "1111111111111111", "error-fixture", 2, 1000000)
    send_trace("22222222222222222222222222222222", "2222222222222222", "slow-fixture", 1, 2000000000)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/api/traces/11111111111111111111111111111111 | jq -e '.batches | length > 0'", timeout=60)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3200/api/traces/22222222222222222222222222222222 | jq -e '.batches | length > 0'", timeout=60)
    machine.succeed("! curl -fsS http://127.0.0.1:3200/api/traces/11111111111111111111111111111111 | grep -E 'TRACE-SECRET|SPAN-SECRET'")
    ordinary_ids = [hashlib.sha256(str(i).encode()).hexdigest()[:32] for i in range(1, 41)]
    for i, trace_id in enumerate(ordinary_ids, 1):
        send_trace(trace_id, f"{i + 256:016x}", "ordinary-fixture", 1, 1000000)
    machine.sleep(5)
    retained = 0
    for trace_id in ordinary_ids:
        status, _ = machine.execute(f"curl -fsS http://127.0.0.1:3200/api/traces/{trace_id}")
        retained += int(status == 0)
    assert 0 < retained < 40, f"ordinary sampling retained {retained}/40"
    machine.succeed("systemctl stop loki.service; curl -fsS -H 'Content-Type: application/json' --data '" + log_payload + "' http://127.0.0.1:4320/v1/logs; timeout 2 true")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8889/metrics | awk '/^otelcol_exporter_send_failed_log_records([{ ]|$)/ && $NF > 0 { found=1 } END { exit !found }'", timeout=45)
    machine.succeed("systemctl start loki.service")
    machine.wait_for_unit("loki.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3000/api/health | jq -e '.database == \"ok\"'")
    auth = "admin:" + machine.succeed("cat /var/lib/telemetry/grafana/admin-password").strip()
    machine.fail("curl -fsS http://127.0.0.1:3000/api/datasources")
    machine.succeed(f"curl -fsS -u '{auth}' http://127.0.0.1:3000/api/datasources | jq -e 'map(.uid) | sort == [\"loki\",\"prometheus\",\"tempo\"]'")
    machine.succeed(f"curl -fsS -u '{auth}' 'http://127.0.0.1:3000/api/search?type=dash-db' | jq -e 'map(.uid) | sort == [\"backups\",\"comin\",\"fleet\",\"ingress\",\"postgres\",\"storage\"]'")
    machine.succeed("test -s /var/lib/telemetry/grafana/admin-password")
    machine.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q TelemetryRefusedOrDropped")
    machine.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q TelemetryDisk75Percent; curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q TelemetryDisk85Percent")
    machine.succeed("mkdir -p /run/observability-test /var/lib/restic-test; printf '%s\\n' /var/lib/restic-test > /run/observability-test/restic-repository; printf '%s\\n' test-password > /run/observability-test/restic-password; RESTIC_REPOSITORY=/var/lib/restic-test RESTIC_PASSWORD_FILE=/run/observability-test/restic-password restic init")
    machine.succeed("sqlite3 /var/lib/telemetry/grafana/grafana.db \"create table if not exists task9_fixture(value text); delete from task9_fixture; insert into task9_fixture values ('restorable');\"")
    machine.succeed("systemctl start fleet-backup-grafana-state.service")
    machine.succeed("RESTIC_REPOSITORY=/var/lib/restic-test RESTIC_PASSWORD_FILE=/run/observability-test/restic-password restic dump latest fleet-payload.tar | tar -tf - > /tmp/grafana-archive; test \"$(grep -Ec '(admin-password|grafana.db|secret-key)$' /tmp/grafana-archive)\" -eq 3; ! grep -E '(prometheus|loki|tempo|dashboards|datasources|alerts)' /tmp/grafana-archive")
    machine.succeed("sqlite3 /var/lib/telemetry/grafana/grafana.db 'delete from task9_fixture'; fleet-restore grafana-state --rehearsal; sleep 2; fleet-restore grafana-state --force")
    machine.succeed("test $(sqlite3 /var/lib/telemetry/grafana/grafana.db 'select value from task9_fixture') = restorable; test $(sqlite3 /var/lib/telemetry/grafana/grafana.db 'pragma integrity_check') = ok")
    for directory, mebibytes in [("prometheus", 257), ("loki", 129), ("tempo", 65), ("grafana", 33)]:
        machine.fail(f"runuser -u {directory} -- dd if=/dev/zero of=/var/lib/telemetry/{directory}/quota-fill bs=1M count={mebibytes} conv=fsync status=none")
        machine.succeed(f"rm -f /var/lib/telemetry/{directory}/quota-fill")
    machine.succeed("findmnt -n -o OPTIONS /var/lib/telemetry | grep -Eq '(^|,)prjquota(,|$)'")
    machine.succeed("systemctl stop var-lib-telemetry.mount")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.wait_until_fails(f"systemctl is-active {unit}.service")
  '';
}
