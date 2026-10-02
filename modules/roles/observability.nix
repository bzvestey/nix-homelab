{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.observability;
  stateRoot = "/var/lib/telemetry";
  gib = 1024 * 1024 * 1024;
  effectiveBudget =
    name:
    if cfg.testMode then cfg.storage.backends.${name}.testBytes else cfg.storage.backends.${name}.bytes;
  totalBudgetBytes = lib.foldl' (total: backend: total + backend.bytes) 0 (
    lib.attrValues cfg.storage.backends
  );
  quotaCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: backend:
      let
        kibibytes = effectiveBudget name / 1024;
      in
      ''
        install -d -m 0750 -o ${backend.owner} -g ${backend.group} ${stateRoot}/${name}
        while IFS= read -r -d "" path; do
          current=$(${pkgs.e2fsprogs}/bin/lsattr -p -d "$path" | ${pkgs.gawk}/bin/awk '{ print $1 }')
          case "$current" in
            0|${toString backend.projectId}) ;;
            *) echo "telemetry quota: $path has project ID $current, expected 0 or ${toString backend.projectId}" >&2; exit 1 ;;
          esac
        done < <(${pkgs.findutils}/bin/find ${stateRoot}/${name} -xdev ! -type l -print0)
        ${pkgs.findutils}/bin/find ${stateRoot}/${name} -xdev ! -type l -exec ${pkgs.e2fsprogs}/bin/chattr -p ${toString backend.projectId} {} +
        ${pkgs.findutils}/bin/find ${stateRoot}/${name} -xdev -type d -exec ${pkgs.e2fsprogs}/bin/chattr +P {} +
        while IFS= read -r -d "" path; do
          test "$(${pkgs.e2fsprogs}/bin/lsattr -p -d "$path" | ${pkgs.gawk}/bin/awk '{ print $1 }')" = ${toString backend.projectId}
        done < <(${pkgs.findutils}/bin/find ${stateRoot}/${name} -xdev ! -type l -print0)
        ${pkgs.quota}/bin/setquota -P ${toString backend.projectId} ${toString kibibytes} ${toString kibibytes} 0 0 ${stateRoot}
      ''
    ) cfg.storage.backends
  );
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
              ''delete_matching_keys(attributes, "(?i)(password|token|secret|authorization|cookie|api[._-]?key|trace[._-]?id|span[._-]?id|container[._-]?id|request[._-]?id|user[._-]?id|session[._-]?id|path|revision)")''
            ];
          }
        ];
      };
      "transform/attribute-safety" = {
        error_mode = "ignore";
        metric_statements = [
          {
            context = "scope";
            statements = [ "keep_keys(attributes, [])" ];
          }
          {
            context = "resource";
            statements = [ ''keep_keys(attributes, ["host.name", "service.name", "deployment.environment"])'' ];
          }
          {
            # Stable operational dimensions only. Request IDs, paths, users,
            # container IDs, revisions, and arbitrary application labels are
            # intentionally excluded to bound Prometheus cardinality.
            context = "datapoint";
            statements = [
              ''keep_keys(attributes, ["cpu", "device", "direction", "filesystem", "interface", "mode", "mountpoint", "operation", "state", "status", "unit"])''
            ];
          }
        ];
        trace_statements = [
          {
            context = "resource";
            statements = [ ''keep_keys(attributes, ["host.name", "service.name", "deployment.environment"])'' ];
          }
          {
            context = "scope";
            statements = [ "keep_keys(attributes, [])" ];
          }
          {
            context = "span";
            statements = [
              "set(span.links, span.links)"
              ''delete_matching_keys(attributes, "(?i)(^|[._-])(password|token|secret|authorization|cookie|api[._-]?key|trace[._-]?id|span[._-]?id|container[._-]?id|request[._-]?id|user[._-]?id|session[._-]?id|path|revision)([._-]|$)")''
            ];
          }
          {
            context = "spanevent";
            statements = [
              ''delete_matching_keys(attributes, "(?i)(^|[._-])(password|token|secret|authorization|cookie|api[._-]?key|trace[._-]?id|span[._-]?id|container[._-]?id|request[._-]?id|user[._-]?id|session[._-]?id|path|revision)([._-]|$)")''
            ];
          }
        ];
        log_statements = [
          {
            context = "scope";
            statements = [ "keep_keys(attributes, [])" ];
          }
          {
            context = "log";
            statements = [
              ''delete_matching_keys(attributes, "(?i)(^|[._-])(password|token|secret|authorization|cookie|api[._-]?key|trace[._-]?id|span[._-]?id|container[._-]?id|request[._-]?id|user[._-]?id|session[._-]?id|path|revision)([._-]|$)")''
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
            "transform/attribute-safety"
            "batch"
          ];
          exporters = [ "prometheus" ];
        };
        logs = {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "transform/log-safety"
            "transform/attribute-safety"
            "batch"
          ];
          exporters = [ "otlphttp/loki" ];
        };
        traces = {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "transform/attribute-safety"
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
    serviceConfig.StateDirectory = lib.mkForce "";
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
    storage = {
      minimumFilesystemBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2000000000000;
        readOnly = true;
      };
      backends = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              projectId = lib.mkOption { type = lib.types.ints.positive; };
              bytes = lib.mkOption { type = lib.types.ints.positive; };
              testBytes = lib.mkOption { type = lib.types.ints.positive; };
              owner = lib.mkOption { type = lib.types.str; };
              group = lib.mkOption { type = lib.types.str; };
            };
          }
        );
        readOnly = true;
        default = {
          prometheus = {
            projectId = 1001;
            bytes = 750 * gib;
            testBytes = 256 * 1024 * 1024;
            owner = "prometheus";
            group = "prometheus";
          };
          loki = {
            projectId = 1002;
            bytes = 500 * gib;
            testBytes = 128 * 1024 * 1024;
            owner = "loki";
            group = "loki";
          };
          tempo = {
            projectId = 1003;
            bytes = 180 * gib;
            testBytes = 64 * 1024 * 1024;
            owner = "tempo";
            group = "tempo";
          };
          grafana = {
            projectId = 1004;
            bytes = 10 * gib;
            testBytes = 32 * 1024 * 1024;
            owner = "grafana";
            group = "grafana";
          };
        };
      };
      totalBudgetBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = totalBudgetBytes;
        readOnly = true;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = totalBudgetBytes <= cfg.storage.minimumFilesystemBytes * 85 / 100;
        message = "Observability backend budgets must reserve at least 15% of the minimum telemetry SSD.";
      }
    ];
    fileSystems.${stateRoot} = lib.mkIf (!cfg.testMode) {
      device = "/dev/disk/by-label/telemetry";
      fsType = "ext4";
      options = [
        "noauto"
        "nofail"
        "prjquota"
      ];
    };
    systemd.tmpfiles.rules = [ "d ${stateRoot} 0755 root root -" ];
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
          ${pkgs.util-linux}/bin/mountpoint -q ${stateRoot}
          ${lib.optionalString (!cfg.testMode) ''
            test "$(${pkgs.coreutils}/bin/df --output=size -B1 ${stateRoot} | tail -1)" -ge ${toString cfg.storage.minimumFilesystemBytes}
          ''}
          ${pkgs.quota}/bin/quotaon -P ${stateRoot} 2>/dev/null || ${pkgs.quota}/bin/quotaon -p ${stateRoot} | grep -q 'project quota on'
          ${quotaCommands}
        '';
      };
      otel-gateway = guard // {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          StateDirectory = lib.mkForce "";
          ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config=file:${gatewayConfig}";
          DynamicUser = true;
          Restart = "on-failure";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };
      grafana = guard // {
        serviceConfig = {
          StateDirectory = lib.mkForce "";
          ExecStartPre = lib.mkBefore [
            "+${pkgs.writeShellScript "grafana-secret-key" ''
              for key in secret-key admin-password; do
                path=${stateRoot}/grafana/$key
                if [ ! -s "$path" ]; then
                  umask 077
                  ${pkgs.openssl}/bin/openssl rand -base64 48 > "$path"
                  chown grafana:grafana "$path"
                fi
              done
            ''}"
          ];
        };
      };
    };

    users = {
      groups.tempo = { };
      users = {
        grafana.createHome = lib.mkForce false;
        loki.createHome = lib.mkForce false;
        tempo = {
          isSystemUser = true;
          group = "tempo";
          home = "${stateRoot}/tempo";
        };
      };
    };
    services = {
      prometheus = {
        enable = true;
        stateDir = "telemetry/prometheus";
        retentionTime = "90d";
        extraFlags = [ "--storage.tsdb.retention.size=${toString (effectiveBudget "prometheus")}B" ];
        ruleFiles = [
          (pkgs.writeText "fleet-alerts.yml" (builtins.toJSON { groups = import ../../alerts/fleet.nix; }))
        ];
        scrapeConfigs = [
          {
            job_name = "fleet-agents";
            honor_labels = true;
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
          server = {
            http_listen_port = 3100;
            grpc_listen_port = 9096;
          };
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
            otlp_config = {
              resource_attributes = {
                ignore_defaults = true;
                attributes_config = [
                  {
                    action = "index_label";
                    attributes = [
                      "host.name"
                      "service.name"
                      "deployment.environment"
                    ];
                  }
                  {
                    action = "drop";
                    regex = "(?i)(password|token|secret|authorization|cookie|api[._-]?key|trace[._-]?id|span[._-]?id|container[._-]?id|path|revision)";
                  }
                ];
              };
              scope_attributes = [
                {
                  action = "drop";
                  regex = ".*";
                }
              ];
              log_attributes = [
                {
                  action = "drop";
                  regex = "(?i)(password|token|secret|authorization|cookie|api[._-]?key|trace[._-]?id|span[._-]?id|container[._-]?id|path|revision)";
                }
              ];
            };
          };
        };
      };
      tempo = {
        enable = true;
        extraFlags = [ "-backend-scheduler.provider.work.compaction.block-retention=336h" ];
        settings = {
          server.http_listen_port = 3200;
          backend_scheduler.local_work_path = "${stateRoot}/tempo/backend-scheduler";
          distributor.receivers.otlp.protocols = {
            grpc.endpoint = "127.0.0.1:4321";
            http.endpoint = "127.0.0.1:4322";
          };
          storage.trace = {
            backend = "local";
            local.path = "${stateRoot}/tempo/blocks";
            wal.path = "${stateRoot}/tempo/wal";
          };
          live_store = {
            shutdown_marker_dir = "${stateRoot}/tempo/live-store/shutdown-marker";
            wal.path = "${stateRoot}/tempo/live-store/wal";
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
          security.admin_password = "$__file{${stateRoot}/grafana/admin-password}";
          security.secret_key = "$__file{${stateRoot}/grafana/secret-key}";
          "auth.anonymous" = {
            enabled = false;
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
                jsonData.manageAlerts = true;
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
      paths = [ "${stateRoot}/grafana" ];
      requiredPaths = [
        "admin-password"
        "grafana.db"
        "secret-key"
      ];
      serviceUnits = [ "grafana.service" ];
      owner = "grafana";
      group = "grafana";
      mode = "0600";
      directoryMode = "0750";
      backupClass = "state";
      maxPayloadBytes = 1073741824;
      createCommand = ''
        ${pkgs.sqlite}/bin/sqlite3 ${stateRoot}/grafana/grafana.db ".backup '$FLEET_BACKUP_STAGING_DIR/grafana.db'"
        install -m 0600 ${stateRoot}/grafana/admin-password "$FLEET_BACKUP_STAGING_DIR/admin-password"
        install -m 0600 ${stateRoot}/grafana/secret-key "$FLEET_BACKUP_STAGING_DIR/secret-key"
        # Keep the bounded transient command observable through systemd's
        # accounting handoff even when this tiny payload completes instantly.
        sleep 1
      '';
      restoreCommand = ''
        install -m 0640 "$FLEET_RESTORE_SOURCE_DIR/grafana.db" ${stateRoot}/grafana/grafana.db
        install -m 0600 "$FLEET_RESTORE_SOURCE_DIR/admin-password" ${stateRoot}/grafana/admin-password
        install -m 0600 "$FLEET_RESTORE_SOURCE_DIR/secret-key" ${stateRoot}/grafana/secret-key
      '';
      healthCheckCommand = ''
        test "$(${pkgs.sqlite}/bin/sqlite3 ${stateRoot}/grafana/grafana.db 'pragma integrity_check')" = ok
        password=$(cat ${stateRoot}/grafana/admin-password)
        for attempt in $(seq 1 30); do
          if ${pkgs.curl}/bin/curl --connect-timeout 1 --max-time 3 -fsS -u "admin:$password" http://127.0.0.1:3000/api/user | ${pkgs.jq}/bin/jq -e '.login == "admin"' >/dev/null; then
            exit 0
          fi
          sleep 1
        done
        exit 1
      '';
      rehearsalCommand = ''test "$(${pkgs.sqlite}/bin/sqlite3 "$FLEET_RESTORE_SOURCE_DIR/grafana.db" 'pragma integrity_check')" = ok'';
      preflightCommand = "${pkgs.util-linux}/bin/findmnt -M ${stateRoot} >/dev/null";
    };
    networking.firewall.extraInputRules = ''
      ip saddr 10.15.4.0/24 tcp dport { 4319, 4320 } accept comment "fleet OTLP gateway"
    '';
  };
}
