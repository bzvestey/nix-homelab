{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.observability;
  stateRoot = "/var/lib/telemetry";
  dashboards = pkgs.linkFarm "fleet-dashboards" (
    map
      (name: {
        inherit name;
        path = ../../dashboards/${name};
      })
      [
        "fleet.json"
        "comin.json"
        "backups.json"
        "storage.json"
        "postgres.json"
        "ingress.json"
      ]
  );
  gatewayConfig = (pkgs.formats.yaml { }).generate "otel-gateway.yaml" {
    receivers.otlp.protocols = {
      grpc.endpoint = "0.0.0.0:4319";
      http.endpoint = "0.0.0.0:4320";
    };
    processors = {
      memory_limiter = {
        check_interval = "1s";
        limit_mib = 512;
        spike_limit_mib = 128;
      };
      batch = {
        timeout = "2s";
        send_batch_size = 1024;
      };
      tail_sampling = {
        decision_wait = "2s";
        num_traces = 10000;
        expected_new_traces_per_sec = 100;
        policies = [
          {
            name = "errors";
            type = "status_code";
            status_code.status_codes = [ "ERROR" ];
          }
          {
            name = "slow";
            type = "latency";
            latency.threshold_ms = 1000;
          }
          {
            name = "baseline";
            type = "probabilistic";
            probabilistic.sampling_percentage = 10;
          }
        ];
      };
      "transform/log-safety" = {
        error_mode = "ignore";
        log_statements = [
          {
            context = "resource";
            statements = [ ''keep_keys(attributes, ["host.name", "service.name", "deployment.environment"])'' ];
          }
          {
            context = "log";
            statements = [
              ''delete_matching_keys(attributes, "(?i)(password|token|secret|authorization|cookie|api[._-]?key|trace[._-]?id|span[._-]?id|container[._-]?id|path|revision)")''
            ];
          }
        ];
      };
    };
    exporters = {
      prometheus = {
        endpoint = "127.0.0.1:9465";
        resource_to_telemetry_conversion.enabled = true;
        sending_queue.enabled = false;
      };
      "otlphttp/loki" = {
        endpoint = "http://127.0.0.1:3100/otlp";
        sending_queue.enabled = false;
        retry_on_failure = {
          enabled = true;
          max_elapsed_time = "30s";
        };
      };
      "otlp/tempo" = {
        endpoint = "127.0.0.1:4321";
        tls.insecure = true;
        sending_queue.enabled = false;
        retry_on_failure = {
          enabled = true;
          max_elapsed_time = "30s";
        };
      };
    };
    service = {
      telemetry.metrics.readers = [
        {
          pull.exporter.prometheus = {
            host = "127.0.0.1";
            port = 8889;
          };
        }
      ];
      pipelines = {
        metrics = {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "batch"
          ];
          exporters = [ "prometheus" ];
        };
        logs = {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "transform/log-safety"
            "batch"
          ];
          exporters = [ "otlphttp/loki" ];
        };
        traces = {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "tail_sampling"
            "batch"
          ];
          exporters = [ "otlp/tempo" ];
        };
      };
    };
  };
  guardedUnits = [
    "prometheus"
    "loki"
    "tempo"
    "grafana"
    "otel-gateway"
  ];
  guard = {
    bindsTo = [ "var-lib-telemetry.mount" ];
    after = [ "var-lib-telemetry.mount" ];
    unitConfig.ConditionPathIsMountPoint = stateRoot;
  };
in
{
  options.fleet.observability = {
    enable = lib.mkEnableOption "central fleet observability stack";
    testMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
    };
    scrapeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (address: "${address}:9464") [
        "10.15.4.4"
        "10.15.4.5"
        "10.15.4.6"
        "10.15.4.7"
        "10.15.4.9"
      ];
      description = "Authoritative LAN host-agent scrape targets.";
    };
  };

  config = lib.mkIf cfg.enable {
    fileSystems.${stateRoot} = lib.mkIf (!cfg.testMode) {
      device = "/dev/disk/by-label/telemetry";
      fsType = "ext4";
      options = [
        "noauto"
        "nofail"
        "prjquota"
      ];
    };
    systemd.tmpfiles.rules =
      map
        (
          entry:
          "d ${stateRoot}/${entry} 0750 ${if entry == "grafana" then "grafana grafana" else "root root"} -"
        )
        [
          "prometheus"
          "loki"
          "tempo"
          "grafana"
        ];
    systemd.services = lib.genAttrs guardedUnits (_: guard) // {
      tempo = guard // {
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "tempo";
          Group = "tempo";
          StateDirectory = lib.mkForce "";
          WorkingDirectory = lib.mkForce "${stateRoot}/tempo";
        };
      };
      telemetry-quotas = guard // {
        before = map (unit: "${unit}.service") guardedUnits;
        requiredBy = map (unit: "${unit}.service") guardedUnits;
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0750 -o prometheus -g prometheus ${stateRoot}/prometheus
          install -d -m 0750 -o loki -g loki ${stateRoot}/loki
          install -d -m 0750 -o tempo -g tempo ${stateRoot}/tempo
          install -d -m 0750 -o grafana -g grafana ${stateRoot}/grafana
          ${pkgs.e2fsprogs}/bin/chattr -p 1001 ${stateRoot}/prometheus
          ${pkgs.e2fsprogs}/bin/chattr -p 1002 ${stateRoot}/loki
          ${pkgs.e2fsprogs}/bin/chattr -p 1003 ${stateRoot}/tempo
          ${pkgs.e2fsprogs}/bin/chattr -p 1004 ${stateRoot}/grafana
          ${pkgs.quota}/bin/setquota -P 1001 0 786432000 0 0 ${stateRoot}
          ${pkgs.quota}/bin/setquota -P 1002 0 524288000 0 0 ${stateRoot}
          ${pkgs.quota}/bin/setquota -P 1003 0 188743680 0 0 ${stateRoot}
          ${pkgs.quota}/bin/setquota -P 1004 0 10485760 0 0 ${stateRoot}
        '';
      };
      otel-gateway = guard // {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config=file:${gatewayConfig}";
          DynamicUser = true;
          Restart = "on-failure";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };
      grafana = guard // {
        serviceConfig.ExecStartPre = lib.mkBefore [
          "+${pkgs.writeShellScript "grafana-secret-key" ''
            key=${stateRoot}/grafana/secret-key
            if [ ! -s "$key" ]; then
              umask 077
              ${pkgs.openssl}/bin/openssl rand -hex 32 > "$key"
              chown grafana:grafana "$key"
            fi
          ''}"
        ];
      };
    };

    users.groups.tempo = { };
    users.users.tempo = {
      isSystemUser = true;
      group = "tempo";
      home = "${stateRoot}/tempo";
    };
    services = {
      prometheus = {
        enable = true;
        stateDir = "telemetry/prometheus";
        retentionTime = "90d";
        extraFlags = [ "--storage.tsdb.retention.size=750GB" ];
        ruleFiles = [
          (pkgs.writeText "fleet-alerts.yml" (builtins.toJSON { groups = import ../../alerts/fleet.nix; }))
        ];
        scrapeConfigs = [
          {
            job_name = "fleet-agents";
            static_configs = [ { targets = cfg.scrapeTargets; } ];
          }
          {
            job_name = "observability";
            static_configs = [
              {
                targets = [
                  "127.0.0.1:8889"
                  "127.0.0.1:9090"
                  "127.0.0.1:3100"
                  "127.0.0.1:3200"
                ];
              }
            ];
          }
          {
            job_name = "otel-gateway";
            static_configs = [ { targets = [ "127.0.0.1:9465" ]; } ];
          }
        ];
      };
      loki = {
        enable = true;
        dataDir = "${stateRoot}/loki";
        configuration = {
          auth_enabled = false;
          server.http_listen_port = 3100;
          common = {
            path_prefix = "${stateRoot}/loki";
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
          };
          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          storage_config.filesystem.directory = "${stateRoot}/loki/chunks";
          compactor = {
            working_directory = "${stateRoot}/loki/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          limits_config = {
            retention_period = "720h";
            allow_structured_metadata = true;
            volume_enabled = true;
          };
        };
      };
      tempo = {
        enable = true;
        extraFlags = [ "-backend-scheduler.provider.work.compaction.block-retention=336h" ];
        settings = {
          server.http_listen_port = 3200;
          distributor.receivers.otlp.protocols = {
            grpc.endpoint = "127.0.0.1:4321";
            http.endpoint = "127.0.0.1:4322";
          };
          storage.trace = {
            backend = "local";
            local.path = "${stateRoot}/tempo/blocks";
            wal.path = "${stateRoot}/tempo/wal";
          };
        };
      };
      grafana = {
        enable = true;
        dataDir = "${stateRoot}/grafana";
        settings = {
          server = {
            http_addr = "127.0.0.1";
            http_port = 3000;
          };
          security.admin_password = "admin";
          security.secret_key = "$__file{${stateRoot}/grafana/secret-key}";
          "auth.anonymous" = {
            enabled = true;
            org_role = "Admin";
          };
        };
        provision = {
          enable = true;
          datasources.settings = {
            apiVersion = 1;
            datasources = [
              {
                name = "Prometheus";
                uid = "prometheus";
                type = "prometheus";
                url = "http://127.0.0.1:9090";
                isDefault = true;
              }
              {
                name = "Loki";
                uid = "loki";
                type = "loki";
                url = "http://127.0.0.1:3100";
                jsonData.derivedFields = [
                  {
                    name = "TraceID";
                    matcherRegex = ''trace_id=(\w+)'';
                    datasourceUid = "tempo";
                    url = "$${__value.raw}";
                  }
                ];
              }
              {
                name = "Tempo";
                uid = "tempo";
                type = "tempo";
                url = "http://127.0.0.1:3200";
                jsonData.tracesToLogsV2.datasourceUid = "loki";
              }
            ];
          };
          dashboards.settings.providers = [
            {
              name = "fleet";
              options.path = dashboards;
              disableDeletion = true;
              allowUiUpdates = false;
            }
          ];
        };
      };
    };
    fleet.backup.jobs.grafana-state = {
      frequency = "*-*-* 02:15:00";
      paths = [ "${stateRoot}/grafana/grafana.db" ];
      requiredPaths = [
        "grafana.db"
        "secret-key"
      ];
      serviceUnits = [ "grafana.service" ];
      owner = "grafana";
      group = "grafana";
      mode = "0640";
      directoryMode = "0750";
      backupClass = "state";
      maxPayloadBytes = 1073741824;
      createCommand = ''
        ${pkgs.sqlite}/bin/sqlite3 ${stateRoot}/grafana/grafana.db ".backup '$FLEET_BACKUP_STAGING_DIR/grafana.db'"
        install -m 0600 ${stateRoot}/grafana/secret-key "$FLEET_BACKUP_STAGING_DIR/secret-key"
      '';
      restoreCommand = ''
        install -m 0640 "$FLEET_RESTORE_SOURCE_DIR/grafana.db" ${stateRoot}/grafana/grafana.db
        install -m 0600 "$FLEET_RESTORE_SOURCE_DIR/secret-key" ${stateRoot}/grafana/secret-key
      '';
      healthCheckCommand = ''test "$(${pkgs.sqlite}/bin/sqlite3 ${stateRoot}/grafana/grafana.db 'pragma integrity_check')" = ok'';
      rehearsalCommand = ''test "$(${pkgs.sqlite}/bin/sqlite3 "$FLEET_RESTORE_SOURCE_DIR/grafana.db" 'pragma integrity_check')" = ok'';
      preflightCommand = "${pkgs.util-linux}/bin/findmnt -M ${stateRoot} >/dev/null";
    };
    networking.firewall.extraInputRules = ''
      ip saddr 10.15.4.0/24 tcp dport { 4319, 4320 } accept comment "fleet OTLP gateway"
    '';
  };
}
