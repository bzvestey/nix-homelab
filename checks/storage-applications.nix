{ host, lib }:
let
  c = host.config;
  containers = c.virtualisation.oci-containers.containers;
  jobs = c.fleet.backup.jobs;
in
assert lib.assertMsg (builtins.all (name: builtins.hasAttr name containers) [
  "jellyfin"
  "kavita"
  "vikunja"
]) "storage role must enable all three applications";
assert containers.jellyfin.ports == [ "127.0.0.1:8096:8096" ];
assert containers.kavita.ports == [ "127.0.0.1:5000:5000" ];
assert containers.vikunja.environment.VIKUNJA_SERVICE_INTERFACE == "127.0.0.1:3456";
assert containers.vikunja.environment.VIKUNJA_DATABASE_HOST == "127.0.0.1:5434";
assert builtins.elem "/mnt/bulk/videos:/data:ro" containers.jellyfin.volumes;
assert builtins.elem "/mnt/bulk/books:/data/books:ro" containers.kavita.volumes;
assert builtins.elem "/mnt/bulk/syncthing:/data/syncthing:ro" containers.kavita.volumes;
assert builtins.all
  (
    name:
    builtins.elem "--device=/dev/dri:/dev/dri" containers.${name}.extraOptions
    && containers.${name}.environment.PUID == "1000"
    && lib.hasInfix ".fleet-restored" c.systemd.services."podman-${name}".serviceConfig.ExecCondition
  )
  [
    "jellyfin"
    "kavita"
  ];
assert builtins.all (mount: mount.automountConfig.TimeoutIdleSec == "0") c.systemd.automounts;
assert jobs.vikunja-db.paths == [ "/var/lib/postgres-vikunja" ];
assert jobs.jellyfin-state.paths == [ "/var/lib/jellyfin" ];
assert jobs.kavita-state.paths == [ "/var/lib/kavita" ];
assert jobs.vikunja-files.paths == [ "/var/lib/vikunja" ];
assert lib.versions.major c.fleet.localPostgres.vikunja.package.version == "18";
assert builtins.all
  (name: jobs.${name}.frequency == "hourly" && jobs.${name}.backupClass == "database")
  [
    "jellyfin-state"
    "kavita-state"
    "vikunja-db"
  ];
assert builtins.all (name: !lib.hasInfix "systemctl stop" jobs.${name}.createCommand) [
  "jellyfin-state"
  "vikunja-files"
];
assert builtins.all (
  mount: lib.hasPrefix "nas.tailbc181.ts.net:" mount.source && mount.dependentUnits != [ ]
) (lib.attrValues c.fleet.storage.nfsMounts);
assert builtins.all
  (
    name:
    lib.hasPrefix "/run/secrets/" c.systemd.services."podman-${name}".unitConfig.ConditionPathExists
  )
  [
    "jellyfin"
    "kavita"
    "vikunja"
  ];
assert lib.assertMsg (containers ? audiobookshelf) "Storage role must enable Audiobookshelf";
assert containers.audiobookshelf.ports == [ "127.0.0.1:13378:13378" ];
assert containers.audiobookshelf.user == "1000:1000";
assert containers.audiobookshelf.environment.PORT == "13378";
assert containers.audiobookshelf.environmentFiles == [ ];
assert lib.hasInfix "@sha256:" containers.audiobookshelf.image;
assert lib.all (volume: builtins.elem volume containers.audiobookshelf.volumes) [
  "/var/lib/audiobookshelf/config:/config"
  "/var/lib/audiobookshelf/metadata:/metadata"
  "/mnt/bulk/book-library:/books:ro"
];
assert
  c.fleet.storage.nfsMounts.books.source == "nas.tailbc181.ts.net:/mnt/spinners-1/Computer/books";
assert
  c.fleet.storage.nfsMounts.book-library.source == "nas.tailbc181.ts.net:/mnt/spinners-1/books";
assert builtins.elem "podman-audiobookshelf" c.fleet.storage.nfsMounts.book-library.dependentUnits;
assert c.fleet.tailscaleServices.services.audiobookshelf.upstream == "http://127.0.0.1:13378";
assert !(c.fleet.tailscaleServiceProxy.proxies ? audiobookshelf);
assert jobs.audiobookshelf-state.paths == [ "/var/lib/audiobookshelf" ];
assert jobs.audiobookshelf-state.interruptsService;
assert jobs.audiobookshelf-state.frequency == "*-*-* 06:00:00 America/Los_Angeles";
true
