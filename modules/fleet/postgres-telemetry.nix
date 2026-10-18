{
  config,
  lib,
  pkgs,
  ...
}:
let
  isolated = config.fleet.localPostgres or { };
  clusters =
    lib.optionalAttrs config.services.postgresql.enable {
      stock = {
        package = config.services.postgresql.package;
        port = config.services.postgresql.settings.port or 5432;
        socket = config.services.postgresql.settings.unix_socket_directories or "/run/postgresql";
        unit = "postgresql";
      };
    }
    // lib.mapAttrs (name: instance: {
      inherit (instance) package port;
      socket = "/run/postgres-${name}";
      unit = "postgres-${name}";
    }) isolated;
  names = lib.optional (clusters ? stock) "stock" ++ builtins.attrNames isolated;
  monitor = "fleet-pg-monitor";
  sql = pkgs.writeText "postgres-monitor.sql" ''
    SELECT 'CREATE ROLE "${monitor}" LOGIN'
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${monitor}')\gexec
    ALTER ROLE "${monitor}" NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
    GRANT pg_monitor TO "${monitor}";
    GRANT CONNECT ON DATABASE postgres TO "${monitor}";
  '';
in
{
  config = lib.mkIf (config.fleet.telemetry.enable && clusters != { }) {
    assertions = [
      {
        assertion = !(builtins.hasAttr "stock" isolated);
        message = "localPostgres name stock is reserved for stock PostgreSQL telemetry";
      }
    ];
    users.groups.${monitor} = { };
    users.users.${monitor} = {
      isSystemUser = true;
      group = monitor;
      extraGroups = map (name: "postgres-${name}") (builtins.attrNames isolated);
    };
    fleet.telemetry.localPrometheusTargets = lib.listToAttrs (
      lib.imap0 (i: name: lib.nameValuePair "postgres-${name}" "127.0.0.1:${toString (9187 + i)}") names
    );
    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: cluster:
        lib.nameValuePair (if name == "stock" then "postgresql-setup" else cluster.unit) {
          postStart = lib.mkAfter ''
            ${cluster.package}/bin/psql -v ON_ERROR_STOP=1 -h ${cluster.socket} -p ${toString cluster.port} -d postgres -f ${sql}
          '';
        }
      ) clusters)
      (lib.listToAttrs (
        lib.imap0 (
          i: name:
          let
            cluster = clusters.${name};
            # Upstream constant labels only cover legacy/custom queries, not
            # the newer built-in collectors. These queries keep identity on all
            # dashboard metrics, including when several clusters share a host.
            queries = pkgs.writeText "postgres-${name}-queries.yaml" (
              builtins.toJSON {
                pg_fleet = {
                  query = "SELECT datname, pg_database_size(datname) AS database_size_bytes, xact_commit AS xact_commit_total, xact_rollback AS xact_rollback_total, numbackends AS connections FROM pg_stat_database WHERE datname IS NOT NULL";
                  metrics = [
                    {
                      datname = {
                        usage = "LABEL";
                        description = "Database name";
                      };
                    }
                    {
                      database_size_bytes = {
                        usage = "GAUGE";
                        description = "Database size in bytes";
                      };
                    }
                    {
                      xact_commit_total = {
                        usage = "COUNTER";
                        description = "Committed transactions";
                      };
                    }
                    {
                      xact_rollback_total = {
                        usage = "COUNTER";
                        description = "Rolled back transactions";
                      };
                    }
                    {
                      connections = {
                        usage = "GAUGE";
                        description = "Current database connections";
                      };
                    }
                  ];
                };
              }
            );
          in
          lib.nameValuePair "postgres-exporter-${name}" {
            wantedBy = [ "multi-user.target" ];
            after = [ "${cluster.unit}.service" ];
            # Deliberately no Requires/PartOf: keep pg_up=0 while PostgreSQL is stopped.
            environment = {
              DATA_SOURCE_NAME = "host=${cluster.socket} port=${toString cluster.port} user=${monitor} dbname=postgres sslmode=disable connect_timeout=3";
              PG_EXPORTER_CONSTANT_LABELS = "cluster=${name}";
              PG_EXPORTER_EXTEND_QUERY_PATH = toString queries;
            };
            serviceConfig = {
              User = monitor;
              Group = monitor;
              ExecStart = "${pkgs.prometheus-postgres-exporter}/bin/postgres_exporter --web.listen-address=127.0.0.1:${toString (9187 + i)}";
              Restart = "always";
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
              ];
            };
          }
        ) names
      ))
    ];
  };
}
