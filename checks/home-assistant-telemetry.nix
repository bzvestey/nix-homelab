{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.prometheus-client ]);
  evaluate =
    enabled:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit pkgs;
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../modules/fleet/home-assistant-telemetry.nix
        {
          system.stateVersion = "26.05";
          fleet.observability.homeAssistant = {
            enable = enabled;
            target = "127.0.0.1:9126";
            tokenFile = "/run/ha-token";
            nativeSources = [
              "grafana"
              "kuma"
              "influxdb"
            ];
            requiredApps = [ "alpha" ];
          };
        }
      ];
    };
  enabled = evaluate true;
  disabled = evaluate false;
  jobs = enabled.config.services.prometheus.scrapeConfigs;
  contracts =
    assert builtins.length jobs == 4;
    assert builtins.all (
      job:
      job.authorization.credentials_file == "/run/ha-token"
      && job.authorization.type == "Bearer"
      && job.scrape_interval == "60s"
      && job.scrape_timeout == "10s"
      && job.sample_limit == (if job.job_name == "homeassistant-platform" then 10000 else 20000)
      && (builtins.head job.static_configs).labels.host_name == "homeassistant"
    ) jobs;
    assert
      map (job: job.metrics_path) jobs == [
        "/metrics"
        "/metrics/grafana"
        "/metrics/kuma"
        "/metrics/influxdb"
      ];
    assert disabled.config.services.prometheus.scrapeConfigs == [ ];
    assert disabled.config.services.prometheus.ruleFiles == [ ];
    assert !disabled.config.services.prometheus.enable;
    assert !disabled.options.fleet.observability.homeAssistant.enable.default;
    assert
      builtins.attrNames enabled.options.fleet.observability.homeAssistant == [
        "enable"
        "nativeSources"
        "requiredApps"
        "target"
        "tokenFile"
      ];
    true;
  fixture = pkgs.writeText "ha-real-collector-fixture.py" ''
    import importlib.util
    import threading
    import time
    from pathlib import Path
    def load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    utility = load("utility", "${./home-assistant-telemetry.py}")
    implementation = load("collector", "${../packages/home-assistant-telemetry}/collector.py")
    upstream = utility.Fixture()
    native = utility.NativeFixture(3000)
    native.body = '# TYPE process_resident_memory_bytes gauge\nprocess_resident_memory_bytes 456\n'
    slug = "a0d7b954_grafana"
    upstream.data['/addons/' + slug + '/info'] = {"ip_address": "127.0.0.1", "host_network": False}
    upstream.data['/addons/' + slug + '/stats'] = utility.stats()
    collector = implementation.Collector(upstream.url, "supervisor-fixture")
    collector.configure_native({"native_grafana": True})
    server = implementation.make_server(collector, "metrics-fixture", "127.0.0.1", 9126)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    while True:
        upstream.fail = {"/core/stats": "error"} if Path("/run/upstream-fail").exists() else {}
        native.body = '# TYPE process_resident_memory_bytes gauge\nprocess_resident_memory_bytes 456\n'
        if Path('/run/native-partial').exists():
            native.body += '# TYPE go_goroutines counter\ngo_goroutines 8\n'
        if Path('/run/native-empty').exists():
            native.body = ""
        upstream.data["/addons"]["addons"] = [utility.inventory("alpha"), utility.inventory("once", "stopped"), utility.inventory(slug)]
        if Path("/run/removed").exists():
            upstream.data["/addons"]["addons"] = [utility.inventory("once", "stopped")]
        collector.poll()
        time.sleep(1)
  '';
  alertTests =
    pkgs.runCommand "home-assistant-alert-contracts"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.prometheus.cli
        ];
      }
      ''
        python3 - <<'PY'
        import json
        from pathlib import Path
        rules = "${builtins.head enabled.config.services.prometheus.ruleFiles}"
        labels = 'job="homeassistant-platform",host_name="homeassistant"'
        def sample(name, value):
            return {"series": name, "values": value}
        healthy = [sample('up{' + labels + '}', '1+0x10')]
        for source in ['inventory', 'core_stats', 'supervisor_stats', 'host']:
            dimensions = labels + ',source="' + source + '",app=""'
            healthy += [sample('haos_collection_success{' + dimensions + '}', '1+0x10'),
                        sample('haos_collection_last_success_timestamp_seconds{' + dimensions + '}', '0+60x10')]
        healthy += [sample('haos_app_state{' + labels + ',app="alpha",state="started"}', '1+0x10'),
                    sample('haos_app_state{' + labels + ',app="cb646a50_get",state="stopped"}', '1+0x10'),
                    sample('haos_host_disk_free_bytes{' + labels + '}', '25+0x10'),
                    sample('haos_host_disk_total_bytes{' + labels + '}', '100+0x10')]
        def contract(inputs, expr, count, at='6m'):
            return {"interval": "1m", "input_series": inputs, "promql_expr_test": [{
                "expr": expr, "eval_time": at,
                "exp_samples": [] if count == 0 else [{"labels": "{}", "value": count}]}]}
        active = 'count(ALERTS{alertstate="firing"})'
        tests = [contract(healthy, active, 0)]
        # Required alpha removed/stopped; the deliberately stopped utility is not required.
        missing = [s for s in healthy if 'app="alpha"' not in s['series']]
        tests += [contract(missing, 'count(ALERTS{alertname="HomeAssistantRequiredAppNotRunning",alertstate="firing"})', 1),
                  contract(missing, active, 0, '4m')]
        unknown = [s for s in healthy if 'source="inventory"' not in s['series']]
        tests += [contract(unknown, 'count(ALERTS{alertname="HomeAssistantCriticalCollectionStale",alertstate="firing"})', 1)]
        disk = [dict(s, values='10+0x10') if s['series'].startswith('haos_host_disk_free') else s for s in healthy]
        tests += [contract(disk, 'count(ALERTS{alertname="HomeAssistantDiskPressure",alertstate="firing"})', 1)]
        down = [dict(s, values='0+0x10') if s['series'].startswith('up{') else s for s in healthy]
        tests += [contract(down, 'count(ALERTS{alertname="HomeAssistantCollectorUnavailable",alertstate="firing"})', 1)]
        stale = [dict(s, values='0+0x10') if 'source="host"' in s['series'] and s['series'].startswith('haos_collection_last') else s for s in healthy]
        tests += [contract(stale, 'count(ALERTS{alertname="HomeAssistantCriticalCollectionStale",alertstate="firing"})', 1, '8m')]
        stopped = missing + [sample('haos_app_state{' + labels + ',app="alpha",state="stopped"}', '1+0x10')]
        tests += [contract(stopped, 'count(ALERTS{alertname="HomeAssistantRequiredAppNotRunning",alertstate="firing"})', 1)]
        Path('alerts.json').write_text(json.dumps({"rule_files": [rules], "evaluation_interval": "1m", "tests": tests}))
        PY
        promtool check rules ${builtins.head enabled.config.services.prometheus.ruleFiles}
        promtool test rules alerts.json
        touch $out
      '';
  vm = pkgs.testers.runNixOSTest {
    name = "home-assistant-telemetry";
    nodes.machine = _: {
      services.prometheus = {
        enable = true;
        checkConfig = "syntax-only";
        scrapeConfigs = map (
          job:
          job
          // {
            scrape_interval = "1s";
            scrape_timeout = "1s";
          }
        ) jobs;
      };
      systemd.tmpfiles.rules = [ "f /run/ha-token 0400 prometheus root - metrics-fixture" ];
      systemd.services.ha-fixture = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${python}/bin/python ${fixture}";
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
    };
    testScript = ''
      start_all()
      machine.wait_for_unit("prometheus.service")
      machine.wait_for_unit("ha-fixture.service")
      def query(expr, expected):
          import shlex
          command = "curl -fsSG --data-urlencode " + shlex.quote("query=" + expr) + " localhost:9090/api/v1/query | jq -e " + shlex.quote(expected)
          machine.wait_until_succeeds(command, timeout=45)
      import json
      from pathlib import Path
      dashboard = json.loads(Path("${../dashboards/home-assistant-apps.json}").read_text())
      native_chart = next(panel for panel in dashboard["panels"] if panel["id"] == 12)["targets"][0]["expr"].replace("''${app:regex}", ".*")
      query('haos_memory_usage_bytes{job="homeassistant-platform",component="core"}', '.data.result[0].value[1] == "321"')
      query('haos_app_state{app="once",state="stopped"}', '.data.result[0].value[1] == "1"')
      query('haos_memory_usage_bytes{app="once"}', '.data.result | length == 0')
      query('process_resident_memory_bytes{job="homeassistant-grafana"}', '.data.result[0].value[1] == "456"')
      query('haos_collection_success{source="native_grafana",app="a0d7b954_grafana"}', '.data.result[0].value[1] == "1"')
      query(native_chart, '.data.result[0].value[1] == "456"')
      machine.succeed("touch /run/native-partial")
      query('haos_collection_success{source="native_grafana",app="a0d7b954_grafana"}', '.data.result[0].value[1] == "0"')
      # A valid family survives the rejected family; dashboards must gate on success.
      query('process_resident_memory_bytes{job="homeassistant-grafana"}', '.data.result[0].value[1] == "456"')
      query('up{job="homeassistant-grafana"}', '.data.result[0].value[1] == "1"')
      query(native_chart, '.data.result | length == 0')
      machine.succeed("touch /run/native-empty")
      query('process_resident_memory_bytes{job="homeassistant-grafana"}', '.data.result | length == 0')
      query('up{job="homeassistant-grafana"}', '.data.result[0].value[1] == "1"')
      machine.succeed("touch /run/upstream-fail")
      query('haos_collection_success{source="core_stats"}', '.data.result[0].value[1] == "0"')
      query('up{job="homeassistant-platform"}', '.data.result[0].value[1] == "1"')
      query('haos_memory_usage_bytes{component="core"}', '.data.result | length == 0')
      query('haos_memory_usage_bytes{app="alpha"}', '.data.result[0].value[1] == "123456789"')
      machine.succeed("touch /run/removed")
      query('haos_app_state{app="alpha"}', '.data.result | length == 0')
      machine.succeed("printf wrong > /run/ha-token")
      query('up{job="homeassistant-platform"}', '.data.result[0].value[1] == "0"')
      query('up{job="homeassistant-grafana"}', '.data.result[0].value[1] == "0"')
    '';
  };
in
assert contracts;
pkgs.linkFarm "home-assistant-telemetry-checks" [
  {
    name = "authenticated-vm";
    path = vm;
  }
  {
    name = "alerts";
    path = alertTests;
  }
]
