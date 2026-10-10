{
  pkgs,
  host,
  node,
}:
let
  inherit (pkgs) lib;
  inventory = builtins.fromJSON (builtins.readFile ../docs/inventory/services.md);
  gate = args: import ./hl-node-02-bootstrap-readiness.nix ({ inherit pkgs host node; } // args);
  accepts = args: (builtins.tryEval (gate args).drvPath).success;
  withHardware = change: {
    inventoryFile = builtins.toFile "bootstrap-hardware-fixture.json" (
      builtins.toJSON (
        inventory
        // {
          targets = map (
            target:
            if target.name == "hl-node-02" then lib.recursiveUpdate target { hardware = change; } else target
          ) inventory.targets;
        }
      )
    );
  };
in
# Bootstrap may pass while production capacity/restore blockers remain.
assert lib.assertMsg (accepts { }) "verified bootstrap should be accepted";
assert
  !accepts (withHardware {
    installDisk.serial = "wrong-device";
  });
assert
  !accepts (withHardware {
    installDisk.capacityBytes = 2000398934015;
  });
assert
  !accepts (withHardware {
    installDisk = {
      status = "blocked";
      reason = "physical identity not yet measured";
      collectionCommand = "lsblk --json";
    };
  });
assert
  !accepts (withHardware {
    nic.stableId = "9c:bf:0d:00:23:fe";
    nic.members = [
      {
        interface = "lan0";
        macAddress = "9c:bf:0d:00:23:fe";
      }
      {
        interface = "lan1";
        macAddress = "9c:bf:0d:00:23:fe";
      }
    ];
  });
assert
  !accepts {
    host = lib.recursiveUpdate host { systemd.services.podman-immich.enable = true; };
  };
assert
  !accepts {
    host = lib.recursiveUpdate host { fleet.storage.nfsMounts.unsafe = { }; };
  };
assert
  !accepts {
    host = lib.recursiveUpdate host { systemd.timers.fleet-backup-immich-db.enable = true; };
  };
assert
  !accepts {
    host = lib.recursiveUpdate host { services.comin.sshAllowedSignersPath = ""; };
  };
assert
  !accepts {
    host = lib.recursiveUpdate host { environment.etc."comin/allowed_signers".text = "untrusted"; };
  };
assert
  !accepts {
    host = lib.recursiveUpdate host { services.comin.remotes = [ ]; };
  };
pkgs.runCommand "bootstrap-readiness-fixtures" { } ''
  touch $out
''
