{ config, lib }:
let
  names = [
    "pocket-id"
    "homarr"
    "donetick"
    "commafeed"
    "mailrise"
    "wallos"
  ];
  containers = config.virtualisation.oci-containers.containers;
  jobs = config.fleet.backup.jobs;
  expectedPorts = {
    pocket-id = "127.0.0.1:1411:1411";
    homarr = "127.0.0.1:7575:3000";
    donetick = "127.0.0.1:2021:2021";
    commafeed = "127.0.0.1:8085:8082";
    wallos = "127.0.0.1:8282:80";
    mailrise = "127.0.0.1:8025:8025";
  };
in
assert lib.all (name: builtins.hasAttr name containers) names;
assert lib.all (name: containers.${name}.extraOptions == [ "--network=fleet-lightweight" ]) names;
assert lib.all (name: containers.${name}.ports == [ expectedPorts.${name} ]) names;
assert lib.all (
  name: lib.all (lib.hasPrefix "/run/secrets/") containers.${name}.environmentFiles
) names;
assert !(builtins.hasAttr "mailrise-state" jobs);
assert lib.all (
  name:
  jobs."${name}-state".serviceUnits == [ "podman-${name}.service" ]
  && lib.hasInfix "systemctl stop" jobs."${name}-state".createCommand
  && lib.hasInfix "state/." jobs."${name}-state".restoreCommand
) (lib.remove "mailrise" names);
assert lib.all (hostname: lib.any (route: route.hostname == hostname) config.fleet.ingress.routes) [
  "donetick.tailbc181.ts.net"
  "feed.tailbc181.ts.net"
  "homarr.tailbc181.ts.net"
  "id.minastas.xyz"
  "wallos.tailbc181.ts.net"
];
assert lib.all (
  name:
  jobs."${name}-state".frequency == "hourly"
  && jobs."${name}-state".backupClass == "database"
  && jobs."${name}-state".paths == [ "/var/lib/${name}" ]
) (lib.remove "mailrise" names);
assert containers.pocket-id.environment.APP_URL == "https://id.minastas.xyz";
assert containers.homarr.environment.DB_URL == "/appdata/db.sqlite";
assert containers.donetick.environment.DT_SQLITE_PATH == "/donetick_data/donetick.db";
assert containers.commafeed.ports == [ "127.0.0.1:8085:8082" ];
assert jobs.pocket-id-state.owner == "1000";
assert jobs.wallos-state.owner == "82";
assert lib.all (
  name: config.systemd.services."podman-${name}".unitConfig.ConditionPathExists != null
) names;
true
