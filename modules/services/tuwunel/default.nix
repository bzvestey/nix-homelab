{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fleet.tuwunel;
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  options.services.fleet.tuwunel = {
    enable = lib.mkEnableOption "pinned Tuwunel with local RocksDB";
    configFile = lib.mkOption {
      type = lib.types.strMatching "^/run/.*";
      default = "/run/secrets/tuwunel.toml";
      description = "Runtime complete TOML retaining Pocket ID settings; no retired Hookshot appservice.";
    };
  };
  config = lib.mkIf cfg.enable {
    systemd = {
      tmpfiles.rules = [
        "d /var/lib/tuwunel 0750 root root -"
        "d /var/lib/tuwunel-backup 0700 root root -"
      ];
      services.podman-tuwunel.unitConfig.ConditionPathExists = cfg.configFile;
    };
    virtualisation.oci-containers = {
      backend = "podman";
      containers.tuwunel = {
        image = "docker.io/jevolk/tuwunel@sha256:0e86c6164d6c9f5b60291938eb61ad8395021c37fe58d47a963ea7edddbedaec";
        environment = {
          TUWUNEL_CONFIG = "/etc/tuwunel.toml";
          TUWUNEL_PORT = "8008";
          TUWUNEL_ADMIN_SIGNAL_EXECUTE = ''["server checkpoint-database --path /var/lib/tuwunel-backup/checkpoint"]'';
          TUWUNEL_ADMIN_EXECUTE_ERRORS_IGNORE = "false";
        };
        volumes = [
          "/var/lib/tuwunel:/var/lib/tuwunel"
          "/var/lib/tuwunel-backup:/var/lib/tuwunel-backup"
          "${cfg.configFile}:/etc/tuwunel.toml:ro"
        ];
        ports = [ "127.0.0.1:8008:8008" ];
      };
    };
    fleet = {
      backup.jobs.tuwunel-state =
        (backups.state {
          name = "tuwunel";
          path = "/var/lib/tuwunel";
          online = true;
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8008/_matrix/client/versions";
        })
        // {
          frequency = "hourly";
          backupClass = "database";
          requiredPaths = [ "state/CURRENT" ];
          createCommand = ''
            checkpoint=/var/lib/tuwunel-backup/checkpoint
            # An interrupted/unfinished request needs investigation, not deletion
            # while RocksDB may still be creating its checkpoint.
            test ! -e "$checkpoint"
            since="$(${pkgs.coreutils}/bin/date --iso-8601=ns)"
            ${pkgs.podman}/bin/podman kill --signal=USR2 tuwunel >/dev/null
            deadline=$((SECONDS + 120))
            while :; do
              ${pkgs.podman}/bin/podman logs --since "$since" tuwunel >"$FLEET_BACKUP_STAGING_DIR/checkpoint.log" 2>&1
              # The console wraps Markdown and colors the checkpoint path.
              if ${pkgs.gnused}/bin/sed 's/\x1b\[[0-9;]*m//g' "$FLEET_BACKUP_STAGING_DIR/checkpoint.log" |
                ${pkgs.coreutils}/bin/tr '\n' ' ' |
                ${pkgs.gnugrep}/bin/grep -E 'Created checkpoint at[[:space:]]+/var/lib/tuwunel-backup/checkpoint\.' >/dev/null; then break; fi
              (( SECONDS < deadline )) || { echo 'Tuwunel checkpoint did not report completion; retained for investigation.' >&2; exit 1; }
              ${pkgs.coreutils}/bin/sleep 1
            done
            test -s "$checkpoint/CURRENT"
            ${pkgs.coreutils}/bin/mkdir -p "$FLEET_BACKUP_STAGING_DIR/state"
            ${pkgs.coreutils}/bin/cp -a --no-preserve=links "$checkpoint/." "$FLEET_BACKUP_STAGING_DIR/state/"
            # Media is outside the RocksDB transaction; never copy the live DB.
            if [ -d /var/lib/tuwunel/media ]; then
              set +e
              ${pkgs.rsync}/bin/rsync -a -- /var/lib/tuwunel/media "$FLEET_BACKUP_STAGING_DIR/state/"
              rc=$?
              set -e
              [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]
            fi
            ${pkgs.coreutils}/bin/rm -r "$checkpoint"
            ${pkgs.coreutils}/bin/rm "$FLEET_BACKUP_STAGING_DIR/checkpoint.log"
          '';
          rehearsalCommand = ''
            manifest="$(${pkgs.coreutils}/bin/cat "$FLEET_RESTORE_SOURCE_DIR/state/CURRENT")"
            [[ "$manifest" =~ ^MANIFEST-[0-9]+$ ]]
            test -s "$FLEET_RESTORE_SOURCE_DIR/state/$manifest"
          '';
        };
      ingress.routes = [
        {
          hostname = "matrix.minastas.social";
          upstream = "http://127.0.0.1:8008";
          exposure = "public";
        }
      ];
    };
  };
}
