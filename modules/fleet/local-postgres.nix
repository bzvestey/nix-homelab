{
  config,
  lib,
  pkgs,
  ...
}:
let
  instances = config.fleet.localPostgres;
in
{
  options.fleet.localPostgres = lib.mkOption {
    default = { };
    description = "Isolated native secondary PostgreSQL clusters; independent of the stock singleton.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          package = lib.mkOption { type = lib.types.package; };
          port = lib.mkOption { type = lib.types.port; };
          environmentFile = lib.mkOption { type = lib.types.strMatching "^/run/.*"; };
          initializeSQL = lib.mkOption { type = lib.types.lines; };
          preloadLibraries = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      }
    );
  };
  config = lib.mkIf (instances != { }) {
    users.groups = lib.mapAttrs' (name: _: lib.nameValuePair "postgres-${name}" { }) instances;
    users.users = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "postgres-${name}" {
        isSystemUser = true;
        group = "postgres-${name}";
      }
    ) instances;
    systemd.services = lib.mapAttrs' (
      name: instance:
      let
        data = "/var/lib/postgres-${name}";
        socket = "/run/postgres-${name}";
        sql = pkgs.writeText "postgres-${name}-initialize.sql" instance.initializeSQL;
        settings = pkgs.writeText "postgres-${name}.conf" ''
          listen_addresses = '127.0.0.1'
          port = ${toString instance.port}
          unix_socket_directories = '${socket}'
          shared_preload_libraries = '${lib.concatStringsSep "," instance.preloadLibraries}'
          password_encryption = 'scram-sha-256'
        '';
        hba = pkgs.writeText "postgres-${name}-hba.conf" ''
          local all all peer
          host app app 127.0.0.1/32 scram-sha-256
        '';
      in
      lib.nameValuePair "postgres-${name}" {
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = instance.environmentFile;
        path = [ instance.package ];
        preStart = ''
          if [ ! -e ${data}/PG_VERSION ]; then
            initdb -D ${data} --encoding=UTF8 --locale=C
          fi
          test "$(cat ${data}/PG_VERSION)" = ${lib.versions.major instance.package.version}
        '';
        postStart = ''
          for attempt in $(seq 1 60); do
            pg_isready -h ${socket} -p ${toString instance.port} && break
            sleep 1
          done
          psql -v ON_ERROR_STOP=1 -h ${socket} -p ${toString instance.port} -d postgres -f ${sql}
        '';
        serviceConfig = {
          User = "postgres-${name}";
          Group = "postgres-${name}";
          StateDirectory = "postgres-${name}";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "postgres-${name}";
          RuntimeDirectoryMode = "0750";
          EnvironmentFile = instance.environmentFile;
          ExecStart = "${instance.package}/bin/postgres -D ${data} -c config_file=${settings} -c hba_file=${hba}";
          KillSignal = "SIGINT";
          TimeoutStopSec = "120";
        };
      }
    ) instances;
  };
}
