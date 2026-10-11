{ configuration }:
let
  c = configuration.config;
  inherit (configuration.pkgs) lib;
  apps = c.virtualisation.oci-containers.containers;
  jobs = c.fleet.backup.jobs;
  names = [
    "forgejo"
    "foundry"
    "tangled-knot"
    "tranquil-pds"
  ];
in
assert c.services.fleet.remainingApplications.enable;
assert builtins.all (
  name: builtins.match ".*@sha256:[0-9a-f]{64}" apps.${name}.image != null
) names;
assert builtins.all (name: apps.${name}.environmentFiles == [ "/run/secrets/${name}.env" ]) names;
assert builtins.all (
  name:
  builtins.elem "/var/lib/${name}/.restored"
    c.systemd.services."podman-${name}".unitConfig.ConditionPathExists
) names;
assert apps.forgejo.environment.FORGEJO__server__ROOT_URL == "https://git.tailbc181.ts.net/";
assert apps.forgejo.environment.FORGEJO__server__SSH_DOMAIN == "git-ssh.tailbc181.ts.net";
assert apps.forgejo.environment.FORGEJO__database__NAME == "app";
assert apps.forgejo.environment.FORGEJO__database__HOST == "127.0.0.1:5434";
assert apps.tangled-knot.environment.KNOT_SEALED_KEY_FILE == "/data/sealed-keys";
assert apps.tangled-knot.environment.KNOT_SSH_HOST_KEY_FILE == "/data/ssh_host_key";
assert
  apps.tangled-knot.ports == [
    "127.0.0.1:5555:5555"
    "127.0.0.1:2223:2222"
  ];
assert apps.tranquil-pds.environment.SERVER_PORT == "8000";
assert apps.tranquil-pds.environment.SERVER_HOST == "127.0.0.1";
assert apps.tranquil-pds.environment.PDS_HOSTNAME == "minastas.social";
assert apps.foundry.ports == [ "127.0.0.1:30000:30000" ];
assert c.fleet.localPostgres.forgejo.port == 5434;
assert c.fleet.localPostgres.tranquil-pds.port == 5435;
assert builtins.all (name: lib.versions.major c.fleet.localPostgres.${name}.package.version == "18")
  [
    "forgejo"
    "tranquil-pds"
  ];
assert jobs.forgejo-db.frequency == "hourly";
assert jobs.tranquil-pds-db.frequency == "hourly";
assert jobs.foundry-state.frequency == "hourly";
assert jobs.tangled-knot-state.frequency == "hourly";
assert builtins.all
  (
    name:
    jobs."${name}-db".paths == [ "/var/lib/postgres-${name}" ]
    && lib.hasInfix "--no-owner --no-acl --role=app -d app" jobs."${name}-db".restoreCommand
  )
  [
    "forgejo"
    "tranquil-pds"
  ];
assert builtins.all (
  name:
  jobs."${name}-state".paths == [ "/var/lib/${name}" ]
  && lib.hasInfix "systemctl stop" jobs."${name}-state".createCommand
) names;
assert jobs.tranquil-pds-state.owner == "65532";
assert jobs.foundry-state.owner == "1000";
assert builtins.all (name: builtins.hasAttr "${name}-state" jobs) [
  "forgejo"
  "foundry"
  "tangled-knot"
  "tranquil-pds"
];
assert c.systemd.services.podman-forgejo.unitConfig.ConditionPathExists != [ ];
true
