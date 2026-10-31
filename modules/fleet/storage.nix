{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.fleet.storage;
  mounts = lib.attrValues cfg.nfsMounts;
  mountUnit = target: "${utils.escapeSystemdPath target}.mount";
  readinessService = target: "nfs-ready-${utils.escapeSystemdPath target}";
in
{
  options.fleet.storage.nfsMounts = lib.mkOption {
    default = { };
    description = "Fail-closed NFS automounts for bulk, non-database data.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.str;
            description = "NFS server and export in server:/path form.";
          };
          target = lib.mkOption {
            type = lib.types.strMatching "^/.*";
            description = "Absolute local mountpoint.";
          };
          dependentUnits = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Services that must stop whenever this mount disappears.";
          };
        };
      }
    );
  };

  config = lib.mkIf (mounts != [ ]) {
    boot.supportedFilesystems = [ "nfs" ];

    systemd = {
      tmpfiles.rules = map (mount: "d ${mount.target} 0555 root root -") mounts;

      mounts = map (mount: {
        what = mount.source;
        where = mount.target;
        type = "nfs";
        options = "_netdev,nfsvers=4.1,hard,timeo=50,retrans=2";
        after = [ "${readinessService mount.target}.service" ];
        requires = [ "${readinessService mount.target}.service" ];
        unitConfig.JobRunningTimeoutSec = "15s";
        mountConfig = {
          TimeoutSec = "10s";
          DirectoryMode = "0555";
        };
      }) mounts;

      automounts = map (mount: {
        where = mount.target;
        wantedBy = [ "multi-user.target" ];
        automountConfig = {
          # Idle expiry would stop services bound to this mount.
          TimeoutIdleSec = if mount.dependentUnits == [ ] then "10min" else "0";
          DirectoryMode = "0555";
        };
      }) mounts;

      services = lib.mkMerge (
        map (
          mount:
          let
            # NFS sources are host:/export or [IPv6]:/export.
            host =
              if lib.hasPrefix "[" mount.source then
                lib.removePrefix "[" (builtins.head (lib.splitString "]:" mount.source))
              else
                builtins.head (lib.splitString ":" mount.source);
          in
          {
            ${readinessService mount.target} = {
              description = "Wait for NFS server for ${mount.target}";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              path = [
                pkgs.getent
                pkgs.netcat-openbsd
              ];
              serviceConfig = {
                Type = "oneshot";
                TimeoutStartSec = "60s";
              };
              # Do not cache readiness: a later mount attempt rechecks the NAS.
              # systemd bounds even stalled resolver calls and kills children.
              script = ''
                host=${lib.escapeShellArg host}
                until getent ahosts "$host" >/dev/null && nc -z -w 1 "$host" 2049 >/dev/null 2>&1; do
                  sleep 1
                done
              '';
            };
          }
        ) mounts
        ++ lib.concatMap (
          mount:
          map (unit: {
            ${unit} = {
              bindsTo = [ (mountUnit mount.target) ];
              after = [ (mountUnit mount.target) ];
              unitConfig.RequiresMountsFor = [ mount.target ];
            };
          }) mount.dependentUnits
        ) mounts
      );
    };
  };
}
