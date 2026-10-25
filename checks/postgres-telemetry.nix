{ pkgs, vikunjaService }:
pkgs.testers.runNixOSTest {
  name = "postgres-telemetry";
  nodes.machine = { config, lib, ... }: {
    imports = [
      ../modules/fleet/local-postgres.nix
      ../modules/fleet/postgres-telemetry.nix
    ];
    options.fleet.telemetry = {
      enable = lib.mkEnableOption "telemetry";
      localPrometheusTargets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
    };
    config = {
      assertions = [
        {
          assertion =
            config.fleet.telemetry.localPrometheusTargets == {
              postgres-stock = "127.0.0.1:9187";
              postgres-alpha = "127.0.0.1:9188";
              postgres-beta = "127.0.0.1:9189";
              postgres-vikunja = "127.0.0.1:9190";
            };
          message = "Each cluster must register its own local scrape target";
        }
      ];
      fleet.telemetry.enable = true;
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_17;
        ensureDatabases = [ "stock_only" ];
      };
      fleet.localPostgres = lib.genAttrs [ "alpha" "beta" "vikunja" ] (name: {
        package = pkgs.postgresql_17;
        port =
          if name == "alpha" then
            5433
          else if name == "beta" then
            5434
          else
            5435;
        environmentFile = "/run/cluster.env";
        initializeSQL = "SELECT 'initialized';";
      });
      systemd.services.postgres-vikunja.serviceConfig.ExecCondition =
        vikunjaService.serviceConfig.ExecCondition;
      users.groups.storage-apps = { };
      systemd.tmpfiles.rules = [
        "f /run/cluster.env 0600 root root - VIKUNJA_DATABASE_PASSWORD=fixture-only"
        "d /var/lib/vikunja 0750 root storage-apps -"
      ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.postgresql_17
      ];
    };
  };
  testScript = ''
    import re
    from datetime import timedelta
    start_all()
    # The real Vikunja database gate must honor missing/empty restore markers,
    # yet permit startup behind the application's private directory boundary.
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl start postgres-vikunja.service")
    machine.fail("systemctl is-active postgres-vikunja.service")
    machine.succeed("touch /var/lib/vikunja/.fleet-restored; systemctl start postgres-vikunja.service")
    machine.fail("systemctl is-active postgres-vikunja.service")
    machine.succeed("echo restored > /var/lib/vikunja/.fleet-restored")
    machine.fail("su -s /bin/sh postgres-vikunja -c 'test -s /var/lib/vikunja/.fleet-restored'")
    machine.succeed("systemctl start postgres-vikunja.service")
    machine.wait_for_unit("postgres-vikunja.service", timeout=timedelta(seconds=20))
    machine.succeed("su -s /bin/sh postgres-vikunja -c 'psql -h /run/postgres-vikunja -p 5435 -d postgres -Atc \"SELECT current_user\"' | grep -x postgres-vikunja")
    machine.wait_for_unit("postgresql.service")
    for name, port in [("alpha", 5433), ("beta", 5434)]:
        machine.wait_for_unit(f"postgres-{name}.service")
        machine.succeed(f"su -s /bin/sh postgres-{name} -c 'psql -h /run/postgres-{name} -p {port} -d postgres -c \"CREATE DATABASE {name}_only\"'")

    def scrape(port):
        return machine.succeed(f"curl -fsS http://127.0.0.1:{port}/metrics")

    for cluster, port, db in [("stock", 9187, "stock_only"), ("alpha", 9188, "alpha_only"), ("beta", 9189, "beta_only")]:
        machine.wait_for_open_port(port, timeout=timedelta(seconds=20))
        metrics = scrape(port)
        assert re.search(r'pg_up\{[^}]*cluster="' + cluster + r'"[^}]*\} 1', metrics), metrics
        for metric in ["pg_fleet_database_size_bytes", "pg_fleet_xact_commit_total", "pg_fleet_xact_rollback_total", "pg_fleet_connections"]:
            assert any(line.startswith(metric + "{") and f'cluster="{cluster}"' in line and f'datname="{db}"' in line for line in metrics.splitlines()), metrics
        for other in {"stock_only", "alpha_only", "beta_only"} - {db}:
            assert f'datname="{other}"' not in metrics
    machine.succeed("systemctl stop postgres-alpha.service")
    assert re.search(r'pg_up\{[^}]*cluster="alpha"[^}]*\} 0', scrape(9188))
    assert re.search(r'pg_up\{[^}]*cluster="beta"[^}]*\} 1', scrape(9189))
    machine.succeed("systemctl start postgres-alpha.service")
    machine.wait_until_succeeds("curl -fsS localhost:9188/metrics | grep 'pg_up{.*} 1'")
    machine.succeed("systemctl stop postgresql.service")
    assert re.search(r'pg_up\{[^}]*cluster="stock"[^}]*\} 0', scrape(9187))
    assert re.search(r'pg_up\{[^}]*cluster="alpha"[^}]*\} 1', scrape(9188))
    machine.succeed("su -s /bin/sh fleet-pg-monitor -c 'psql -h /run/postgres-alpha -p 5433 -d postgres -Atc \"SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname = current_user\"' | grep -x f")
    machine.fail("su -s /bin/sh fleet-pg-monitor -c 'psql -h /run/postgres-alpha -p 5433 -d postgres -c \"CREATE DATABASE forbidden\"'")
  '';
}
