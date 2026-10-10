{
  pkgs,
  host,
  node,
  inventoryFile ? ../docs/inventory/services.md,
}:
let
  inherit (pkgs) lib;
  inventory = builtins.fromJSON (builtins.readFile inventoryFile);
  target = lib.findFirst (target: target.name == "hl-node-02") null inventory.targets;
  inherit (target) hardware;
  schema = import ./inventory.nix { inherit pkgs lib inventoryFile; };
  workloads = [
    "podman-immich"
    "podman-immich-ml"
    "podman-mealie"
    "podman-tuwunel"
    "postgres-immich"
    "postgresql"
    "postgresql-setup"
    "dragonflydb"
    "caddy"
    "forgejo-runner-hl\\x2dnode\\x2d02"
  ];
  backups = map (job: "fleet-backup-${job}") (
    builtins.attrNames host.fleet.backup.jobs ++ [ "check" ]
  );
  members = map (member: {
    interface = member;
    macAddress = node.nic.permanentMacAddresses.${member};
  }) node.nic.members;
in
assert lib.assertMsg (builtins.isString schema.drvPath) "bootstrap: inventory schema must pass";
assert lib.assertMsg (target != null) "bootstrap: hl-node-02 inventory is missing";
assert lib.assertMsg (
  target.address == node.address && target.architecture == node.system
) "bootstrap: target address/architecture mismatch";
assert lib.assertMsg (lib.all
  (
    field: target.hardwareRequirements.${field} == "required" && hardware.${field}.status == "observed"
  )
  [
    "installDisk"
    "nic"
    "gpu"
  ]
) "bootstrap: disk/NIC/GPU observations are required";
assert lib.assertMsg (
  hardware.installDisk.byIdPath == node.installDisk.byId
  && hardware.installDisk.model == node.installDisk.model
  && hardware.installDisk.serial == node.installDisk.serial
  && hardware.installDisk.capacityBytes == node.installDisk.sectors * 512
) "bootstrap: disk observation does not match installer pins";
assert lib.assertMsg (
  hardware.nic.addressKind == "permanent"
  && lib.sort (a: b: a.interface < b.interface) hardware.nic.members == members
) "bootstrap: NIC observations do not match permanent installer identities";
assert lib.assertMsg (
  hardware.gpu.pciId == node.gpuPciId && hardware.gpu.deviceAddress == "0000:00:02.0"
) "bootstrap: GPU observation does not match installer pins";
assert lib.assertMsg (
  host.networking.hostName == "hl-node-02"
) "bootstrap: wrong target configuration";
assert lib.assertMsg (lib.all (name: !host.systemd.services.${name}.enable) (
  workloads ++ backups
)) "bootstrap: workloads/databases/runner/backups must be masked";
assert lib.assertMsg (lib.all (
  name: !host.systemd.timers.${name}.enable
) backups) "bootstrap: backup timers must be masked";
assert lib.assertMsg (
  host.fleet.storage.nfsMounts == { }
  && lib.all (
    mount:
    !(builtins.elem mount.type [
      "nfs"
      "nfs4"
    ])
  ) host.systemd.mounts
  && lib.all (mount: mount.where != "/mnt/bulk/immich") host.systemd.automounts
) "bootstrap: production NFS must be absent";
assert lib.assertMsg (
  host.services.openssh.enable && host.fleet.telemetry.enable && host.services.comin.enable
) "bootstrap: SSH, telemetry and comin must remain enabled";
assert lib.assertMsg (
  !host.fleet.comin.enableMirror
  && builtins.length host.services.comin.remotes == 1
  && (builtins.head host.services.comin.remotes).name == "github"
  && (builtins.head host.services.comin.remotes).url == "https://github.com/bzvestey/nix-homelab.git"
  && (builtins.head host.services.comin.remotes).branches.main.name == "main"
  && (builtins.head host.services.comin.remotes).branches.main.operation == "switch"
  && host.services.comin.sshAllowedSignersPath == "/etc/comin/allowed_signers"
  &&
    host.environment.etc."comin/allowed_signers".text
    == "bryan@vestey.dev ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpx0yPdFPKUFBLn6OKJJAyqnlvoLmll4m97l/YMLu8\n"
) "bootstrap: trusted-signature GitHub-only comin policy is required";
pkgs.runCommand "hl-node-02-bootstrap-readiness" { } ''
  touch $out
''
