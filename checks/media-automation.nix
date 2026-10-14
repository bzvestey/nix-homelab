{ config, lib }:
let
  containers = config.virtualisation.oci-containers.containers;
  apps = [
    "deluge"
    "prowlarr"
    "radarr"
    "sonarr"
    "whisparr"
    "sabnzbd"
    "publication-manager"
  ];
  disruptive = [
    "deluge"
    "sabnzbd"
    "publication-manager"
  ];
in
assert config.services.fleet.mediaAutomation.enable;
assert lib.all (name: builtins.hasAttr name containers) apps;
assert containers.deluge.ports == [ ];
assert builtins.elem "--network=container:gluetun" containers.deluge.extraOptions;
assert builtins.elem "--network=container:gluetun" containers.deluge-port-manager.extraOptions;
assert
  containers.gluetun.ports == [
    "127.0.0.1:8112:8112"
    "127.0.0.1:58846:58846"
  ];
assert !builtins.elem "--network=host" containers.gluetun.extraOptions;
assert containers.gluetun.environment.FIREWALL == "on";
assert lib.all (name: builtins.elem "/mnt/bulk/videos:/videos" containers.${name}.volumes) [
  "deluge"
  "radarr"
  "sonarr"
  "whisparr"
  "sabnzbd"
];
assert builtins.elem "/mnt/bulk/deluge-downloads:/downloads" containers.deluge.volumes;
assert containers.sabnzbd.ports == [ "127.0.0.1:8180:8080" ];
assert builtins.elem "--authfile=/run/secrets/publication-manager-registry.json"
  containers.publication-manager.extraOptions;
assert lib.all (
  name:
  let
    job = config.fleet.backup.jobs."${name}-state";
  in
  job.frequency
  == (if builtins.elem name disruptive then "*-*-* 06:00:00 America/Los_Angeles" else "hourly")
  && job.backupClass == "database"
  && lib.all (path: lib.hasPrefix "/var/lib/media-automation/" path) job.paths
) apps;
assert builtins.elem "podman-gluetun.service" config.systemd.services.podman-deluge.bindsTo;
assert builtins.elem "podman-deluge-port-manager.service"
  config.fleet.backup.jobs.deluge-state.serviceUnits;
assert
  config.fleet.storage.nfsMounts.videos.source == "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
assert
  config.fleet.storage.nfsMounts.deluge-downloads.source
  == "nas.tailbc181.ts.net:/mnt/spinners-1/kube-store/deluge/downloads";
assert
  config.fleet.storage.nfsMounts.publications.source
  == "nas.tailbc181.ts.net:/mnt/spinners-1/Computer";
assert lib.all
  (
    name:
    let
      unit = config.systemd.services."podman-${name}";
    in
    builtins.elem "mnt-bulk-videos.mount" unit.bindsTo
    && builtins.elem "/mnt/bulk/videos" unit.unitConfig.RequiresMountsFor
  )
  [
    "deluge"
    "radarr"
    "sonarr"
    "whisparr"
    "sabnzbd"
  ];
assert lib.all (
  name:
  let
    job = config.fleet.backup.jobs."${name}-state";
  in
  job.owner == "1000"
  && job.group == "1000"
  && job.directoryMode == "0700"
  && containers.${name}.environmentFiles == [ "/run/secrets/${name}.env" ]
  && (lib.hasInfix "systemctl stop" job.createCommand == builtins.elem name disruptive)
) apps;
# The stopped-source Sonarr archive measured about 1.58 GiB at migration.
assert config.fleet.backup.jobs.sonarr-state.maxPayloadBytes >= 1698247656;
assert lib.all (name: lib.hasInfix "@sha256:" containers.${name}.image) (
  apps
  ++ [
    "gluetun"
    "deluge-port-manager"
  ]
);
assert lib.all (name: lib.all (port: lib.hasPrefix "127.0.0.1:" port) containers.${name}.ports) (
  apps ++ [ "gluetun" ]
);
assert
  lib.length (lib.unique (lib.concatMap (name: containers.${name}.ports) (apps ++ [ "gluetun" ])))
  == 8;
true
