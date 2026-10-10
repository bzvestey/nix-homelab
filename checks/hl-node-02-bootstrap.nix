{
  pkgs,
  comin,
  nixosConfigurations,
}:
let
  inherit (pkgs) lib;
  host = nixosConfigurations.hl-node-02.config;
  applicationPaths = {
    immich-env = "/run/secrets/immich.env";
    mealie-env = "/run/secrets/mealie.env";
    tuwunel-config = "/run/secrets/tuwunel.toml";
    restic-repository = "/run/secrets/restic-repository";
    restic-password = "/run/secrets/restic-password";
    restic-s3-credentials = "/run/secrets/restic-s3-credentials";
  };
  applicationFixture =
    pkgs.runCommand "hl-node-02-application-secrets-fixture"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
      }
      ''
        age-keygen -o disposable-key.txt 2>/dev/null
        recipient=$(age-keygen -y disposable-key.txt)
        cat >applications.yaml <<'EOF'
        immich-env: DB_PASSWORD=synthetic
        mealie-env: POSTGRES_PASSWORD=synthetic
        tuwunel-config: '[global]'
        restic-repository: /var/lib/synthetic-repository
        restic-password: synthetic
        restic-s3-credentials: synthetic
        EOF
        mkdir -p "$out"
        sops --config /dev/null --encrypt --age "$recipient" applications.yaml >"$out/applications.yaml"
        rm disposable-key.txt applications.yaml
      '';
  prospectiveHost =
    # extendModules retains the complete host, including its sops-nix import.
    (nixosConfigurations.hl-node-02.extendModules {
      modules = [
        {
          _module.args.hlNode02ApplicationSecretsFile = lib.mkForce "${applicationFixture}/applications.yaml";
          # Evaluation checks mappings, not decryption; avoid import-from-derivation.
          sops.validateSopsFiles = lib.mkForce false;
        }
      ];
    }).config;
  workloads = [
    "podman-immich"
    "podman-immich-ml"
    "podman-mealie"
    "podman-tuwunel"
    "postgres-immich"
    "postgresql"
    "postgresql-setup"
    "dragonflydb"
    "forgejo-runner-hl\\x2dnode\\x2d02"
    "caddy"
  ];
  backups = map (job: "fleet-backup-${job}") [
    "immich-db"
    "mealie-db"
    "mealie-state"
    "tuwunel-state"
    "check"
  ];
  testPkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = package: lib.getName package == "dragonflydb";
  };
in
assert lib.assertMsg (
  builtins.attrNames host.sops.secrets
  == builtins.attrNames (applicationPaths // { tailscale-auth-key = null; })
) "hl-node-02 bootstrap: default host must integrate all seven secrets";
assert lib.assertMsg (lib.all
  (
    name:
    let
      secret = host.sops.secrets.${name};
    in
    secret.key == name
    && secret.path == applicationPaths.${name}
    && secret.owner == "root"
    && secret.group == "root"
    && secret.mode == "0600"
    && secret.restartUnits == [ ]
    && toString secret.sopsFile == toString ../secrets/hosts/hl-node-02/applications.yaml
  )
  (builtins.attrNames applicationPaths)
) "hl-node-02 bootstrap: default application secret mappings and ciphertext source";
assert host.fleet.backup.s3CredentialsFile == "/run/secrets/restic-s3-credentials";
assert lib.assertMsg (lib.all
  (
    name:
    let
      secret = prospectiveHost.sops.secrets.${name};
    in
    secret.key == name
    && secret.path == applicationPaths.${name}
    && secret.owner == "root"
    && secret.group == "root"
    && secret.mode == "0600"
    && secret.restartUnits == [ ]
    && toString secret.sopsFile == "${applicationFixture}/applications.yaml"
  )
  (builtins.attrNames applicationPaths)
) "hl-node-02 bootstrap: dormant application secret mappings";
assert prospectiveHost.fleet.backup.s3CredentialsFile == "/run/secrets/restic-s3-credentials";
assert lib.all (name: !prospectiveHost.systemd.services.${name}.enable) workloads;
assert lib.all (
  name:
  !prospectiveHost.systemd.services.${name}.enable && !prospectiveHost.systemd.timers.${name}.enable
) backups;
assert prospectiveHost.fleet.storage.nfsMounts == { };
assert lib.all (
  mount:
  !(builtins.elem mount.type [
    "nfs"
    "nfs4"
  ])
) prospectiveHost.systemd.mounts;
assert lib.all (mount: mount.where != "/mnt/bulk/immich") prospectiveHost.systemd.automounts;
assert lib.assertMsg (lib.all (
  name: !host.systemd.services.${name}.enable
) workloads) "hl-node-02 bootstrap: workload units must be masked";
assert lib.all (
  name: !host.systemd.services.${name}.enable && !host.systemd.timers.${name}.enable
) backups;
assert host.fleet.storage.nfsMounts == { };
assert lib.all (
  mount:
  !(builtins.elem mount.type [
    "nfs"
    "nfs4"
  ])
) host.systemd.mounts;
assert lib.all (mount: mount.where != "/mnt/bulk/immich") host.systemd.automounts;
assert host.services.openssh.enable && host.fleet.telemetry.enable;
assert host.services.comin.enable;
assert map (remote: remote.name) host.services.comin.remotes == [ "github" ];
pkgs.linkFarm "hl-node-02-bootstrap-checks" [
  {
    name = "encrypted-fixture";
    path = applicationFixture;
  }
  {
    name = "bootstrap-vm";
    path = testPkgs.testers.runNixOSTest {
      name = "hl-node-02-bootstrap";
      nodes.machine = {
        imports = [
          comin.nixosModules.comin
          ../modules/fleet/comin.nix
          ../modules/fleet/podman.nix
          ../modules/fleet/storage.nix
          ../modules/fleet/backup.nix
          ../modules/fleet/ingress.nix
          ../modules/fleet/telemetry-agent.nix
          ../modules/roles/application-services.nix
          ../modules/services/forgejo-runner
          ../hosts/hl-node-02/bootstrap.nix
        ];
        networking.hostName = "hl-node-02";
        # The real host policy is asserted above; fixtures must never poll live Git.
        services.comin.enable = lib.mkForce false;
        services.fleet = {
          immich.librarySource = "unreachable.invalid:/production-library";
          forgejo-runner = {
            enable = true;
            inherit (host.services.fleet.forgejo-runner) uuid;
          };
        };
        fleet.ingress.enableTailscale = false;
        fleet.ingress.testUseInternalTls = true;
        virtualisation.memorySize = 2048;
      };
      testScript = ''
        import shlex
        start_all()
        machine.wait_for_unit("multi-user.target")
        # Credentials being present must not turn bootstrap into production.
        machine.succeed("install -d -m 700 /run/secrets; printf 'DB_PASSWORD=fixture\n' >/run/secrets/immich.env; printf 'POSTGRES_PASSWORD=fixture\n' >/run/secrets/mealie.env; printf '[global]\n' >/run/secrets/tuwunel.toml; printf fixture >/run/secrets/forgejo-runner-hl-node-02; printf /var/lib/fixture-repository >/run/secrets/restic-repository; printf fixture >/run/secrets/restic-password; chmod 600 /run/secrets/*")
        machine.succeed("printf '[default]\\naws_access_key_id=fixture\\naws_secret_access_key=fixture\\n' >/run/secrets/restic-s3-credentials; chmod 600 /run/secrets/restic-s3-credentials")
        units = ${
          builtins.toJSON (
            map (name: "${name}.service") (workloads ++ backups) ++ map (name: "${name}.timer") backups
          )
        }
        for unit in units:
            quoted_unit = shlex.quote(unit)
            assert machine.succeed(f"systemctl is-enabled {quoted_unit} || true").strip() == "masked", unit
            machine.fail(f"systemctl start {quoted_unit}")
            machine.fail(f"systemctl is-active --quiet {quoted_unit}")
        machine.succeed("test -z \"$(find /var/lib -name PG_VERSION -print -quit)\"")
        machine.fail("systemctl cat mnt-bulk-immich.mount")
        machine.fail("systemctl cat mnt-bulk-immich.automount")
        machine.fail("findmnt -rn -t nfs,nfs4")
        machine.succeed("command -v fleet-restore; command -v fleet-backup-run")
      '';
    };
  }
]
