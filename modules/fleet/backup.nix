{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.backup;
  jobType = lib.types.submodule {
    options = {
      frequency = lib.mkOption {
        type = lib.types.str;
        description = "systemd OnCalendar schedule for the backup.";
      };
      paths = lib.mkOption {
        type = lib.types.nonEmptyListOf (lib.types.strMatching "^/.*");
        description = "Restore destinations whose ownership and modes are managed.";
      };
      requiredPaths = lib.mkOption {
        type = lib.types.nonEmptyListOf (lib.types.strMatching "^[A-Za-z0-9][A-Za-z0-9._/-]*$");
        description = "Relative regular files or non-empty directories required in the staged payload.";
      };
      createCommand = lib.mkOption {
        type = lib.types.lines;
        description = "Export command; FLEET_BACKUP_STAGING_DIR is set.";
      };
      restoreCommand = lib.mkOption {
        type = lib.types.lines;
        description = "Import command; FLEET_RESTORE_SOURCE_DIR is set.";
      };
      serviceUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Units stopped in listed order and started in reverse order.";
      };
      healthCheckCommand = lib.mkOption {
        type = lib.types.lines;
        description = "Post-restore health and data check, invoked without arguments.";
      };
      preflightCommand = lib.mkOption {
        type = lib.types.lines;
        default = "true";
        description = "Fail-closed restore prerequisite check.";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Owner recursively applied to restored paths.";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Group recursively applied to restored paths.";
      };
      mode = lib.mkOption {
        type = lib.types.strMatching "[0-7]{3,4}";
        default = "0750";
        description = "Mode applied to restored regular files.";
      };
      directoryMode = lib.mkOption {
        type = lib.types.strMatching "[0-7]{3,4}";
        default = "0750";
        description = "Mode applied to restored directories.";
      };
      backupClass = lib.mkOption {
        type = lib.types.enum [
          "database"
          "state"
        ];
        default = "state";
        description = "Alert class: database is stale at 90m, state at 26h.";
      };
      failedStagingGenerations = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Maximum failed staging generations retained locally.";
      };
      failedStagingBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1073741824;
        description = "Maximum total bytes retained across failed staging generations per job.";
      };
      maxPayloadBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1073741824;
        description = "Maximum logical payload and archive bytes accepted during backup or restore.";
      };
      rehearsalCommand = lib.mkOption {
        type = lib.types.lines;
        default = "true";
        description = "Non-destructive validation run with FLEET_RESTORE_SOURCE_DIR during --rehearsal.";
      };
    };
  };
  tools = pkgs.callPackage ../../packages/fleet-restore.nix {
    inherit (cfg) jobs passwordFile repositoryFile;
  };
  mkService = name: _: {
    description = "Verified fleet backup for ${name}";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${tools}/bin/fleet-backup-run ${lib.escapeShellArg name}";
      StateDirectory = "fleet-backup";
    };
    unitConfig = {
      ConditionPathIsReadable = [
        cfg.repositoryFile
        cfg.passwordFile
      ];
    };
  };
  mkTimer = name: job: {
    description = "Staggered fleet backup for ${name}";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = job.frequency;
      Persistent = true;
      RandomizedDelaySec = "20m";
      FixedRandomDelay = true;
    };
  };
in
{
  options.fleet.backup = {
    repositoryFile = lib.mkOption {
      type = lib.types.strMatching "^/.*";
      default = "/run/secrets/restic-repository";
      description = "Runtime file containing this host's isolated repository URL.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.strMatching "^/.*";
      default = "/run/secrets/restic-password";
      description = "Runtime restic password file.";
    };
    jobs = lib.mkOption {
      type = lib.types.attrsOf jobType;
      default = { };
      description = "Service-consistent backup and restore jobs.";
    };
  };

  config = lib.mkIf (cfg.jobs != { }) {
    environment.systemPackages = [ tools ];
    systemd.services =
      lib.mapAttrs' (name: job: lib.nameValuePair "fleet-backup-${name}" (mkService name job)) cfg.jobs
      // {
        fleet-backup-check = {
          description = "Weekly rotating restic repository integrity check";
          serviceConfig = {
            ExecStart = "${tools}/bin/fleet-backup-check";
            StateDirectory = "fleet-backup";
          };
          unitConfig.ConditionPathIsReadable = [
            cfg.repositoryFile
            cfg.passwordFile
          ];
        };
      };
    systemd.timers =
      lib.mapAttrs' (name: job: lib.nameValuePair "fleet-backup-${name}" (mkTimer name job)) cfg.jobs
      // {
        fleet-backup-check = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "weekly";
            Persistent = true;
            RandomizedDelaySec = "6h";
            FixedRandomDelay = true;
          };
        };
      };
  };
}
