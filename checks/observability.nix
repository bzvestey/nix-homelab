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
      s3CredentialsFile = "/run/observability-test/restic-s3-credentials";
    };
    services.prometheus.exporters.node = {
      enable = true;
      port = 9464;
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector" ];
    };
    virtualisation.emptyDiskImages = [
      2047
      2048
    ];
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
        assertion = config.fleet.observability.storage.minimumFilesystemBytes == 2000000000000;
        message = "telemetry minimum must be an exact decimal 2 TB";
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
    machine.succeed("mkfs.ext4 -F -L telemetry-small -O project,quota /dev/vdb")
    machine.succeed("mkfs.ext4 -F -L telemetry -O project,quota /dev/vdc")
    machine.wait_until_succeeds("test -e /dev/disk/by-label/telemetry-small && test -e /dev/disk/by-label/telemetry")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.fail(f"systemctl is-active {unit}.service")
    machine.wait_for_unit("systemd-tmpfiles-setup.service")
    machine.succeed("mkdir -p /var/lib/telemetry; test -z \"$(find /var/lib/telemetry -mindepth 1 -print -quit)\"")
    machine.succeed("mount -o prjquota /dev/disk/by-label/telemetry-small /var/lib/telemetry")
    machine.wait_until_succeeds("findmnt -M /var/lib/telemetry")
    machine.succeed("test $(blockdev --getsize64 /dev/vdb) -lt 2147483648")
    machine.fail("systemctl start telemetry-quotas.service")
    machine.succeed("systemctl reset-failed telemetry-quotas.service; umount /var/lib/telemetry")
    machine.succeed("mount -o prjquota /dev/disk/by-label/telemetry /var/lib/telemetry")
    machine.wait_until_succeeds("findmnt -M /var/lib/telemetry")
    machine.succeed("test $(blockdev --getsize64 /dev/vdc) -ge 2147483648")
    machine.succeed("test $(df --output=size -B1 /var/lib/telemetry | tail -1) -lt 2147483648")
    machine.succeed("mkdir -p /var/lib/telemetry/prometheus/preexisting/nested; echo adopted > /var/lib/telemetry/prometheus/preexisting/nested/file")
    machine.succeed("mkdir -p /var/lib/telemetry/loki/wrong-project; ${pkgs.e2fsprogs}/bin/chattr -p 9999 /var/lib/telemetry/loki/wrong-project")
    machine.fail("systemctl start telemetry-quotas.service")
    machine.succeed("rm -rf /var/lib/telemetry/loki/wrong-project; systemctl reset-failed telemetry-quotas.service")
    machine.succeed("systemctl reset-failed; systemctl start prometheus loki tempo grafana otel-gateway")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.wait_for_unit(f"{unit}.service")
    machine.wait_for_open_port(4319)
    for project, directory in [(1001, "prometheus"), (1002, "loki"), (1003, "tempo"), (1004, "grafana")]:
        machine.succeed(f"touch /var/lib/telemetry/{directory}/quota-child; test $(${pkgs.e2fsprogs}/bin/lsattr -p /var/lib/telemetry/{directory}/quota-child | awk '{{print $1}}') = {project}")
        machine.succeed(f"find /var/lib/telemetry/{directory} -type d -exec ${pkgs.e2fsprogs}/bin/lsattr -d {{}} + | awk '$1 !~ /P/ {{ exit 1 }}'")
    machine.succeed("test $(${pkgs.e2fsprogs}/bin/lsattr -p /var/lib/telemetry/prometheus/preexisting/nested/file | awk '{print $1}') = 1001")
    now = machine.succeed("date +%s%N").strip()
    metric = '{"resourceMetrics":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"fixture-host"}},{"key":"service.name","value":{"stringValue":"fixture-app"}},{"key":"deployment.environment","value":{"stringValue":"test"}}]},"scopeMetrics":[{"scope":{"attributes":[{"key":"scope.token","value":{"stringValue":"METRIC-SCOPE-SECRET"}}]},"metrics":[{"name":"fleet_fixture_metric","gauge":{"dataPoints":[{"asDouble":7,"timeUnixNano":"' + now + '","attributes":[{"key":"request.token","value":{"stringValue":"METRIC-POINT-SECRET"}}]}]}}]}]}]}'
    machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + metric + "' http://127.0.0.1:4320/v1/metrics")
    machine.wait_until_succeeds("curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=fleet_fixture_metric' | jq -e '.data.result | length > 0'", timeout=60)
    machine.succeed("! curl -fsS http://127.0.0.1:9465/metrics | grep -E 'METRIC-SCOPE-SECRET|METRIC-POINT-SECRET'")
    now = machine.succeed("date +%s%N").strip()
    log_payload = '{"resourceLogs":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"fixture-host"}},{"key":"service.name","value":{"stringValue":"fixture-app"}},{"key":"deployment.environment","value":{"stringValue":"test"}},{"key":"cloud.token","value":{"stringValue":"RESOURCE-SECRET"}},{"key":"container.id","value":{"stringValue":"high-cardinality"}}]},"scopeLogs":[{"scope":{"attributes":[{"key":"scope.secret","value":{"stringValue":"LOG-SCOPE-SECRET"}}]},"logRecords":[{"timeUnixNano":"' + now + '","body":{"stringValue":"benign gateway log"},"attributes":[{"key":"HTTP.Request.Header.Authorization","value":{"stringValue":"SIGNAL-SECRET"}},{"key":"request.id","value":{"stringValue":"unbounded-label"}}]}]}]}]}'
    machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + log_payload + "' http://127.0.0.1:4320/v1/logs")
    machine.wait_until_succeeds("curl -GfsS --data-urlencode 'query={service_name=\"fixture-app\"} |= \"benign gateway log\"' http://127.0.0.1:3100/loki/api/v1/query_range | jq -e '.data.result | length == 1'", timeout=60)
    machine.succeed("curl -GfsS --data-urlencode 'match[]={deployment_environment=\"test\",host_name=\"fixture-host\",service_name=\"fixture-app\"}' http://127.0.0.1:3100/loki/api/v1/series | jq -e '.data | length == 1 and (.[0] | keys | sort) == [\"deployment_environment\",\"host_name\",\"service_name\"]'")
    machine.succeed("curl -fsS http://127.0.0.1:3100/loki/api/v1/labels | jq -e '[.data[] | select(test(\"(?i)(password|token|secret|authorization|cookie|api_?key|trace_?id|span_?id|container_?id|path|revision|request_?id)\"))] | length == 0'")
    machine.succeed("! curl -GfsS --data-urlencode 'query={service_name=\"fixture-app\"}' http://127.0.0.1:3100/loki/api/v1/query_range | grep -E 'RESOURCE-SECRET|SIGNAL-SECRET|LOG-SCOPE-SECRET|high-cardinality|unbounded-label'")
    def send_trace(trace_id, span_id, name, status, duration):
        start = int(machine.succeed("date +%s%N").strip())
        trace = '{"resourceSpans":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"fixture-host"}},{"key":"service.name","value":{"stringValue":"fixture-app"}},{"key":"deployment.environment","value":{"stringValue":"test"}},{"key":"db.password","value":{"stringValue":"TRACE-SECRET"}}]},"scopeSpans":[{"scope":{"attributes":[{"key":"scope.api_key","value":{"stringValue":"TRACE-SCOPE-SECRET"}}]},"spans":[{"traceId":"' + trace_id + '","spanId":"' + span_id + '","name":"' + name + '","kind":2,"startTimeUnixNano":"' + str(start) + '","endTimeUnixNano":"' + str(start + duration) + '","status":{"code":' + str(status) + '},"attributes":[{"key":"HTTP.Authorization.Token","value":{"stringValue":"SPAN-SECRET"}}],"events":[{"timeUnixNano":"' + str(start) + '","name":"fixture-event","attributes":[{"key":"event.password","value":{"stringValue":"SPAN-EVENT-SECRET"}}]}]}]}]}]}'
        machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + trace + "' http://127.0.0.1:4320/v1/traces")
    def send_linked_trace(trace_id, span_id, name, status, duration, sentinel):
        start = int(machine.succeed("date +%s%N").strip())
        trace = '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"fixture-app"}}]},"scopeSpans":[{"spans":[{"traceId":"' + trace_id + '","spanId":"' + span_id + '","name":"' + name + '","startTimeUnixNano":"' + str(start) + '","endTimeUnixNano":"' + str(start + duration) + '","status":{"code":' + str(status) + '},"links":[{"traceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","spanId":"aaaaaaaaaaaaaaaa","attributes":[{"key":"link.token","value":{"stringValue":"' + sentinel + '"}}]}]}]}]}]}'
        machine.succeed("curl -fsS -H 'Content-Type: application/json' --data '" + trace + "' http://127.0.0.1:4320/v1/traces")
    send_linked_trace("33333333333333333333333333333333", "3333333333333333", "linked-error-fixture", 2, 1000000, "ERROR-LINK-SECRET")
    send_linked_trace("44444444444444444444444444444444", "4444444444444444", "linked-slow-fixture", 1, 2000000000, "SLOW-LINK-SECRET")
    send_trace("11111111111111111111111111111111", "1111111111111111", "error-fixture", 2, 1000000)
    send_trace("22222222222222222222222222222222", "2222222222222222", "slow-fixture", 1, 2000000000)
    for trace_id in ["11111111111111111111111111111111", "22222222222222222222222222222222", "33333333333333333333333333333333", "44444444444444444444444444444444"]:
        machine.wait_until_succeeds(f"curl -fsS http://127.0.0.1:3200/api/traces/{trace_id} | jq -e '.batches | length > 0'", timeout=60)
    machine.succeed("! curl -fsS http://127.0.0.1:3200/api/traces/11111111111111111111111111111111 | grep -E 'TRACE-SECRET|SPAN-SECRET|TRACE-SCOPE-SECRET|SPAN-EVENT-SECRET|SPAN-LINK-SECRET'")
    for trace_id in ["33333333333333333333333333333333", "44444444444444444444444444444444"]:
        machine.succeed(f"curl -fsS http://127.0.0.1:3200/api/traces/{trace_id} | jq -e '[.. | objects | select(has(\"links\")) | .links | length] | all(. == 0)'")
    machine.succeed("! (curl -fsS http://127.0.0.1:3200/api/traces/33333333333333333333333333333333; curl -fsS http://127.0.0.1:3200/api/traces/44444444444444444444444444444444) | grep -E 'ERROR-LINK-SECRET|SLOW-LINK-SECRET|aaaaaaaaaaaaaaaa'")
    ordinary_ids = [hashlib.sha256(str(i).encode()).hexdigest()[:32] for i in range(1, 41)]
    for i, trace_id in enumerate(ordinary_ids, 1):
        send_trace(trace_id, f"{i + 256:016x}", "ordinary-fixture", 1, 1000000)
    machine.sleep(5)
    retained = 0
    for trace_id in ordinary_ids:
        status, _ = machine.execute(f"curl -fsS http://127.0.0.1:3200/api/traces/{trace_id}")
        retained += int(status == 0)
    assert 0 < retained < 40, f"ordinary sampling retained {retained}/40"
    machine.succeed("systemctl stop loki.service; timeout 2 curl -fsS -H 'Content-Type: application/json' --data '" + log_payload + "' http://127.0.0.1:4320/v1/logs")
    machine.succeed("systemctl is-active otel-gateway.service; curl -fsS http://127.0.0.1:9090/-/ready")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8889/metrics | awk '/^otelcol_exporter_send_failed_log_records([{ ]|$)/ && $NF > 0 { found=1 } END { exit !found }'", timeout=45)
    machine.succeed("systemctl start loki.service")
    machine.wait_for_unit("loki.service")
    auth = "admin:" + machine.succeed("cat /var/lib/telemetry/grafana/admin-password").strip()
    machine.wait_until_succeeds(f"curl --connect-timeout 1 --max-time 3 -fsS -u '{auth}' http://127.0.0.1:3000/api/user | jq -e '.login == \"admin\"'", timeout=30)
    machine.fail("curl -fsS http://127.0.0.1:3000/api/datasources")
    machine.succeed(f"curl -fsS -u '{auth}' http://127.0.0.1:3000/api/datasources | jq -e 'map(.uid) | sort == [\"loki\",\"prometheus\",\"tempo\"]'")
    machine.succeed(f"curl -fsS -u '{auth}' 'http://127.0.0.1:3000/api/search?type=dash-db' | jq -e 'map(.uid) | sort == [\"backups\",\"comin\",\"fleet\",\"ingress\",\"postgres\",\"storage\"]'")
    machine.succeed("test -s /var/lib/telemetry/grafana/admin-password")
    machine.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q TelemetryRefusedOrDropped")
    machine.succeed("mkdir -p /var/lib/node_exporter/textfile_collector; printf '%s\\n' 'otelcol_receiver_refused_spans 0' 'otelcol_receiver_refused_log_records 0' > /var/lib/node_exporter/textfile_collector/otel-colliding-labels.prom")
    machine.wait_until_succeeds("curl -GfsS --data-urlencode 'query=count({__name__=~\"otelcol_receiver_refused_(spans|log_records)\"})' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result[0].value[1] == \"2\"'", timeout=30)
    previous_evaluation = machine.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | jq -r '.data.groups[].rules[] | select(.name == \"TelemetryRefusedOrDropped\") | .lastEvaluation'").strip()
    machine.wait_until_succeeds(f"curl -fsS http://127.0.0.1:9090/api/v1/rules | jq -e '.data.groups[].rules[] | select(.name == \"TelemetryRefusedOrDropped\") | .lastEvaluation != \"{previous_evaluation}\"'", timeout=90)
    machine.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | jq -e '.data.groups[].rules[] | select(.name == \"TelemetryRefusedOrDropped\") | .health == \"ok\" and .state == \"inactive\"'")
    machine.succeed("printf '%s\\n' 'otelcol_receiver_refused_spans 3' 'otelcol_receiver_refused_log_records 7' > /var/lib/node_exporter/textfile_collector/otel-colliding-labels.prom")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9090/api/v1/rules | jq -e '.data.groups[].rules[] | select(.name == \"TelemetryRefusedOrDropped\") | .health == \"ok\" and .state == \"firing\"'", timeout=90)
    machine.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q TelemetryDisk75Percent; curl -fsS http://127.0.0.1:9090/api/v1/rules | grep -q TelemetryDisk85Percent")
    machine.succeed("mkdir -p /run/observability-test")
    credentials = ["restic-repository", "restic-password", "restic-s3-credentials"]
    for missing in credentials:
        for present in credentials:
            machine.succeed(f"touch /run/observability-test/{present}")
        machine.succeed(f"rm /run/observability-test/{missing}")
        for unit in ["fleet-backup-grafana-state", "fleet-backup-check"]:
            machine.succeed(f"systemctl reset-failed {unit}; systemctl start {unit}; systemctl show {unit} -p Result --value | grep -qx exec-condition")
    machine.succeed("printf '%s\\n' '[default]' 'aws_access_key_id = fixture-access' 'aws_secret_access_key = fixture-secret' > /run/observability-test/restic-s3-credentials")
    machine.succeed("mkdir -p /run/observability-test /var/lib/restic-test; printf '%s\\n' /var/lib/restic-test > /run/observability-test/restic-repository; printf '%s\\n' test-password > /run/observability-test/restic-password; RESTIC_REPOSITORY=/var/lib/restic-test RESTIC_PASSWORD_FILE=/run/observability-test/restic-password restic init")
    machine.succeed("sqlite3 /var/lib/telemetry/grafana/grafana.db \"create table if not exists task9_fixture(value text); delete from task9_fixture; insert into task9_fixture values ('restorable');\"")
    machine.succeed("systemctl start fleet-backup-grafana-state.service")
    machine.succeed("RESTIC_REPOSITORY=/var/lib/restic-test RESTIC_PASSWORD_FILE=/run/observability-test/restic-password restic dump latest fleet-payload.tar | tar -tf - > /tmp/grafana-archive; test \"$(grep -Ec '(admin-password|grafana.db|secret-key)$' /tmp/grafana-archive)\" -eq 3; ! grep -E '(prometheus|loki|tempo|dashboards|datasources|alerts)' /tmp/grafana-archive")
    machine.succeed("sqlite3 /var/lib/telemetry/grafana/grafana.db 'delete from task9_fixture'; fleet-restore grafana-state --rehearsal; sleep 5; fleet-restore grafana-state --force")
    machine.succeed("test $(sqlite3 /var/lib/telemetry/grafana/grafana.db 'select value from task9_fixture') = restorable; test $(sqlite3 /var/lib/telemetry/grafana/grafana.db 'pragma integrity_check') = ok; test $(stat -c %a /var/lib/telemetry/grafana/admin-password) = 600; test $(stat -c %a /var/lib/telemetry/grafana/secret-key) = 600")
    restored_auth = "admin:" + machine.succeed("cat /var/lib/telemetry/grafana/admin-password").strip()
    machine.wait_until_succeeds(f"curl --connect-timeout 1 --max-time 3 -fsS -u '{restored_auth}' http://127.0.0.1:3000/api/user | jq -e '.login == \"admin\"'", timeout=30)
    machine.succeed("curl -fsS -o /tmp/node-metrics http://127.0.0.1:9464/metrics; grep -q 'fleet_backup_result{class=\"state\",job=\"grafana-state\"} 1' /tmp/node-metrics; grep -q 'fleet_restore_result{job=\"grafana-state\"' /tmp/node-metrics; grep -q 'fleet_restore_rehearsal_result{job=\"grafana-state\"' /tmp/node-metrics")
    for query, value in [("fleet_backup_result", "1"), ("fleet_restore_result", "1"), ("fleet_restore_rehearsal_result", "1"), ("fleet_backup_alert_threshold_seconds", "93600")]:
        machine.wait_until_succeeds(f"curl -GfsS --data-urlencode 'query={query}{{job=\"grafana-state\"}}' http://127.0.0.1:9090/api/v1/query | jq -e '.data.result[0].value[1] == \"{value}\"'", timeout=120)
    machine.succeed("curl -fsS http://127.0.0.1:9090/api/v1/rules | jq -e '[.data.groups[].rules[] | select(.name == \"BackupStale\" or .name == \"BackupOrRestoreFailed\") | .query] | tostring | test(\"fleet_backup_|fleet_restore_\")'; curl -fsS -u '" + restored_auth + "' 'http://127.0.0.1:3000/api/dashboards/uid/backups' | jq -e '[.dashboard.panels[].targets[].expr] | tostring | test(\"fleet_backup_\") and test(\"fleet_restore_rehearsal_\")'")
    for directory, mebibytes in [("prometheus", 257), ("loki", 129), ("tempo", 65), ("grafana", 33)]:
        machine.fail(f"runuser -u {directory} -- dd if=/dev/zero of=/var/lib/telemetry/{directory}/quota-fill bs=1M count={mebibytes} conv=fsync status=none")
        machine.succeed(f"rm -f /var/lib/telemetry/{directory}/quota-fill")
    machine.succeed("findmnt -n -o OPTIONS /var/lib/telemetry | grep -Eq '(^|,)prjquota(,|$)'")
    machine.succeed("systemctl stop var-lib-telemetry.mount")
    for unit in ["prometheus", "loki", "tempo", "grafana", "otel-gateway"]:
        machine.wait_until_fails(f"systemctl is-active {unit}.service")
  '';
}
