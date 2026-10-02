{
  config,
  lib,
  ...
}:
let
  cfg = config.fleet.storage;
  mounts = lib.attrValues cfg.nfsMounts;
  mountUnit =
    target: "${lib.replaceStrings [ "-" "/" ] [ "\\x2d" "-" ] (lib.removePrefix "/" target)}.mount";
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
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        unitConfig.JobRunningTimeoutSec = "15s";
        mountConfig.TimeoutSec = "10s";
      }) mounts;

      automounts = map (mount: {
        where = mount.target;
        wantedBy = [ "multi-user.target" ];
        automountConfig.TimeoutIdleSec = "10min";
      }) mounts;

      services = lib.mkMerge (
        lib.concatMap (
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
