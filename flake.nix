{
  description = "NixOS homelab fleet";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      comin,
      disko,
      nixos-hardware,
      sops-nix,
      ...
    }:
    let
      revision = self.rev or self.dirtyRev or "dirty-local";
      mkHost = import ./lib/mk-host.nix { inherit nixpkgs revision; };
      fleetTopologyLib = import ./lib/fleet-topology.nix { inherit (nixpkgs) lib; };
      inherit (fleetTopologyLib) fleetTopology mkFleetTopology;
      cominPackage =
        system:
        nixpkgs.legacyPackages.${system}.callPackage ./packages/comin.nix {
          inherit (comin.packages.${system}) comin;
        };
      correctedCominModule =
        { pkgs, ... }:
        {
          services.comin.package = cominPackage pkgs.stdenv.hostPlatform.system;
        };
      fleetModules = [
        sops-nix.nixosModules.sops
        correctedCominModule
        ./modules/fleet/secrets.nix
        ./modules/fleet/podman.nix
        ./modules/fleet/storage.nix
        ./modules/fleet/backup.nix
        ./modules/fleet/telemetry-agent.nix
        ./modules/fleet/ingress.nix
        ./modules/fleet/cloudflared.nix
      ];
      frameworkModules = fleetModules ++ [ disko.nixosModules.disko ];
      piModules = fleetModules ++ [
        nixos-hardware.nixosModules.raspberry-pi-5
        ./modules/hardware/raspberry-pi-5.nix
      ];
      hardwareModules = {
        framework = frameworkModules;
        raspberry-pi-5 = piModules;
      };
      roleModules =
        let
          modules = {
            observability = [ ./modules/roles/observability-node.nix ];
            lightweight-services = [ ./modules/roles/lightweight-services.nix ];
            application-services = [ ];
            storage-services = [ ./modules/roles/storage-services.nix ];
            developer-media-services = [ ./modules/roles/developer-media-services.nix ];
          };
        in
        assert nixpkgs.lib.assertMsg (
          builtins.attrNames modules == builtins.attrNames fleetTopology.roleAssignments
        ) "role module lookup must exactly match fleet topology roles";
        modules;
      selectRoleModules =
        topology: nodeId: nixpkgs.lib.concatMap (role: roleModules.${role}) (topology.rolesForNode nodeId);
      modulesForNode =
        nodeId: node:
        hardwareModules.${node.hardwareClass}
        ++ [
          comin.nixosModules.comin
          ./modules/fleet/base.nix
          ./modules/fleet/networking.nix
          ./modules/fleet/role-aliases.nix
          ./modules/fleet/comin.nix
          ./modules/fleet/telemetry-agent.nix
          { fleet.telemetry.enable = true; }
          { _module.args = { inherit fleetTopology; }; }
          (./hosts + "/${nodeId}")
        ]
        ++ selectRoleModules fleetTopology nodeId;
      nixosConfigurations = nixpkgs.lib.mapAttrs (
        nodeId: node:
        mkHost {
          inherit (node) system;
          hostname = nodeId;
          modules = modulesForNode nodeId node;
        }
      ) fleetTopology.nodes;
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-linux"
        "x86_64-linux"
      ];
      frameworkFacts = nixpkgs.lib.mapAttrs (_: node: {
        diskById = node.installDisk.byId;
        diskModel = node.installDisk.model;
        diskSerial = node.installDisk.serial;
        diskSectors = node.installDisk.sectors;
        nicMembers = node.nic.members;
        nicMac = node.nic.macAddress;
        inherit (node) gpuPciId address;
      }) (nixpkgs.lib.filterAttrs (_: node: node.hardwareClass == "framework") fleetTopology.nodes);
      mkFrameworkImage =
        targetHost:
        (nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = frameworkFacts.${targetHost} // {
            inherit disko targetHost;
            targetSystem = nixosConfigurations.${targetHost}.config.system.build.toplevel;
          };
          modules = [
            comin.nixosModules.comin
            correctedCominModule
            ./modules/fleet/base.nix
            ./modules/fleet/networking.nix
            ./modules/fleet/comin.nix
            ./installers/framework-iso.nix
          ];
        }).config.system.build.isoImage;
      mkPiImageConfiguration =
        targetHost:
        let
          node = fleetTopology.nodes.${targetHost};
        in
        mkHost {
          inherit (node) system;
          hostname = targetHost;
          modules = modulesForNode targetHost node ++ [
            {
              _module.args = {
                inherit targetHost;
                telemetryIdentity = null;
              };
              imports = [ ./installers/rpi-image.nix ];
            }
          ];
        };
      piImageConfigurations = nixpkgs.lib.genAttrs (builtins.filter (
        nodeId: fleetTopology.nodes.${nodeId}.imageType == "rpi"
      ) fleetTopology.nodeIds) mkPiImageConfiguration;
      images = nixpkgs.lib.genAttrs fleetTopology.nodeIds (
        nodeId:
        if fleetTopology.nodes.${nodeId}.imageType == "rpi" then
          piImageConfigurations.${nodeId}.config.system.build.sdImage
        else
          mkFrameworkImage nodeId
      );
    in
    {
      inherit images nixosConfigurations;

      lib = {
        inherit fleetTopology mkFleetTopology mkHost;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = forAllSystems (system: {
        inherit (nixpkgs.legacyPackages.${system}) deadnix statix;
        comin = cominPackage system;
        fleet-enroll = nixpkgs.legacyPackages.${system}.callPackage ./packages/fleet-enroll.nix { };
        fleet-restore = nixpkgs.legacyPackages.${system}.callPackage ./packages/fleet-restore.nix {
          jobs = { };
          repositoryFile = "/run/secrets/restic-repository";
          passwordFile = "/run/secrets/restic-password";
        };
      });

      apps = forAllSystems (system: {
        inventory-readiness = {
          type = "app";
          program = toString (
            nixpkgs.legacyPackages.${system}.writeShellScript "inventory-readiness" ''
              exec nix build --impure --expr '
                let
                  flake = builtins.getFlake "${self}";
                in
                import ${self}/checks/inventory.nix {
                  inherit (flake.inputs.nixpkgs) lib;
                  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
                  inventoryFile = ${self}/docs/inventory/services.md;
                  readiness = true;
                }
              '
            ''
          );
        };
      });

      checks = forAllSystems (system: {
        no-legacy-hostnames = nixpkgs.legacyPackages.${system}.runCommand "no-legacy-hostnames" { } ''
          ${nixpkgs.legacyPackages.${system}.bash}/bin/bash ${./checks/no-legacy-hostnames.sh} ${self}
          touch $out
        '';
        wave-1-runbook = nixpkgs.legacyPackages.${system}.runCommand "wave-1-runbook" { } ''
          ${nixpkgs.legacyPackages.${system}.bash}/bin/bash ${./checks/wave-1-runbook.sh} ${self}
          touch $out
        '';
        fleet-topology = import ./checks/fleet-topology.nix {
          inherit fleetTopology mkFleetTopology selectRoleModules;
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
        };
        pi-firmware = import ./checks/pi-firmware.nix {
          inherit nixosConfigurations piImageConfigurations;
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
        };
        ingress = import ./checks/ingress.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
        observability = import ./checks/observability.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
        telemetry-agent = import ./checks/telemetry-agent.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
        backup-restore =
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          pkgs.linkFarm "backup-restore-checks" [
            {
              name = "integration";
              path = import ./checks/backup-restore.nix { inherit nixpkgs pkgs; };
            }
            {
              name = "cgroup-vm";
              path = import ./checks/backup-cgroup.nix { inherit pkgs; };
            }
          ];
        installers = import ./checks/installers.nix {
          inherit disko;
          pkgs = nixpkgs.legacyPackages.${system};
        };
        storage = import ./checks/storage.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
        secrets = import ./checks/secrets.nix {
          inherit comin sops-nix;
          pkgs = nixpkgs.legacyPackages.${system};
          fleetEnroll = self.packages.${system}.fleet-enroll;
          includeVm = false;
        };
        secrets-vm = import ./checks/secrets.nix {
          inherit comin sops-nix;
          pkgs = nixpkgs.legacyPackages.${system};
          fleetEnroll = self.packages.${system}.fleet-enroll;
        };
        common-host = import ./checks/common-host.nix {
          inherit nixosConfigurations piImageConfigurations;
          inherit (nixpkgs) lib;
          cominPackageFor = cominPackage;
          pkgs = nixpkgs.legacyPackages.${system};
        };
        evaluation = import ./checks/evaluation.nix {
          inherit images nixosConfigurations;
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
        };
        inventory = import ./checks/inventory.nix {
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
        };
        inventory-fixtures =
          let
            pkgs = nixpkgs.legacyPackages.${system};
            fixture =
              file: expectedErrors:
              import ./checks/inventory.nix {
                inherit pkgs expectedErrors;
                inherit (nixpkgs) lib;
                inventoryFile = file;
                readiness = true;
                fixtureMode = true;
              };
            tests = [
              (fixture ./checks/fixtures/zero-size.json [ "schema:data:invalid-size" ])
              (fixture ./checks/fixtures/negative-size.json [ "schema:data:invalid-size" ])
              (fixture ./checks/fixtures/unknown-size.json [ "schema:data:invalid-size" ])
              (fixture ./checks/fixtures/unknown-target.json [ "schema:data:unknown-target" ])
              (fixture ./checks/fixtures/duplicate-dataset.json [ "schema:duplicate-dataset:shared" ])
              (fixture ./checks/fixtures/amd64-only.json [ "readiness:bad-arch:missing-linux-arm64" ])
              (fixture ./checks/fixtures/oversized.json [
                "readiness:hl-node-02:insufficient-measured-free-space"
              ])
              (fixture ./checks/fixtures/missing-evidence.json [
                "readiness:no-evidence:backup-blocked"
                "readiness:no-evidence:restore-blocked"
              ])
              (fixture ./checks/fixtures/missing-hardware.json [
                "schema:hl-node-02:invalid-hardware-gpu"
                "schema:hl-node-02:invalid-hardware-installDisk"
                "schema:hl-node-02:invalid-hardware-nic"
              ])
              (fixture ./checks/fixtures/sysfs-hardware.json [
                "readiness:hl-node-02:free-bytes-blocked"
                "readiness:hl-node-02:installDisk-blocked"
              ])
              (fixture ./checks/fixtures/malformed-observed-evidence.json [
                "schema:data:invalid-size"
              ])
              (fixture ./checks/fixtures/missing-database-dataset.json [
                "schema:db-app:invalid-database"
                "schema:db-app:missing-database-dataset"
              ])
              (fixture ./checks/fixtures/mismatched-database-dataset.json [
                "schema:db-app:database-dataset-owner-mismatch"
                "schema:db-app:invalid-database"
                "schema:db-app:invalid-database-dataset-evidence"
              ])
              (fixture ./checks/fixtures/database-unrelated-path.json [
                "schema:app:invalid-database-dataset-evidence"
              ])
              (fixture ./checks/fixtures/database-identity-mismatch.json [
                "schema:app:invalid-database-dataset-evidence"
              ])
              (fixture ./checks/fixtures/database-size-observation-mismatch.json [
                "schema:app:invalid-database-dataset-evidence"
              ])
              (fixture ./checks/fixtures/database-coverage-matching.json [ ])
              (fixture ./checks/fixtures/empty-architectures.json [
                "schema:empty-arch:dependency-not-retained:retired-service"
                "schema:empty-arch:invalid-architectures"
              ])
              (fixture ./checks/fixtures/shared-accounting.json [ ])
              (fixture ./checks/fixtures/duplicate-nic-interface.json [
                "schema:duplicate-nic:invalid-hardware-nic"
              ])
            ];
          in
          pkgs.runCommand "inventory-fixtures" { } ''
            ${nixpkgs.lib.concatMapStringsSep "\n" (test: "test -e ${test}") tests}
            touch $out
          '';
      });
    };
}
