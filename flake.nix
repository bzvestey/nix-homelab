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
      fleetModules = [
        sops-nix.nixosModules.sops
        ./modules/fleet/secrets.nix
        ./modules/fleet/podman.nix
        ./modules/fleet/storage.nix
        ./modules/fleet/backup.nix
        ./modules/fleet/telemetry-agent.nix
        ./modules/fleet/ingress.nix
        ./modules/fleet/cloudflared.nix
      ];
      frameworkModules = fleetModules ++ [ disko.nixosModules.disko ];
      nixosConfigurations = {
        observability-pi = mkHost {
          system = "aarch64-linux";
          hostname = "observability-pi";
          modules = fleetModules ++ [
            comin.nixosModules.comin
            ./hosts/observability-pi
          ];
        };
        framework-01 = mkHost {
          system = "x86_64-linux";
          hostname = "framework-01";
          modules = frameworkModules ++ [
            comin.nixosModules.comin
            ./hosts/framework-01
          ];
        };
        framework-02 = mkHost {
          system = "x86_64-linux";
          hostname = "framework-02";
          modules = frameworkModules ++ [
            comin.nixosModules.comin
            ./hosts/framework-02
          ];
        };
        framework-03 = mkHost {
          system = "x86_64-linux";
          hostname = "framework-03";
          modules = frameworkModules ++ [
            comin.nixosModules.comin
            ./hosts/framework-03
          ];
        };
        services-pi = mkHost {
          system = "aarch64-linux";
          hostname = "services-pi";
          modules = fleetModules ++ [
            comin.nixosModules.comin
            ./hosts/services-pi
          ];
        };
      };
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-linux"
        "x86_64-linux"
      ];
      frameworkFacts = {
        framework-01 = {
          diskById = "UNRESOLVED";
          diskModel = "Samsung SSD 970 EVO Plus 2TB";
          diskSerial = "S59CNM0W713317D";
          diskSectors = 3907029168;
          nicMembers = [
            "enp0s13f0u1"
            "enp0s13f0u2"
          ];
          nicMac = "9c:bf:0d:00:23:fe";
          gpuPciId = "8086:9a49";
          address = "10.15.4.5";
        };
        framework-02 = {
          diskById = "UNRESOLVED";
          diskModel = "Samsung SSD 980 1TB";
          diskSerial = "S64ANS0RB36721W";
          diskSectors = 1953525168;
          nicMembers = [
            "enp0s13f0u3"
            "enp0s13f0u4"
          ];
          nicMac = "9c:bf:0d:00:0d:3c";
          gpuPciId = "8086:4626";
          address = "10.15.4.7";
        };
        framework-03 = {
          diskById = "UNRESOLVED";
          diskModel = "Samsung SSD 980 1TB";
          diskSerial = "S64ANL0T801753P";
          diskSectors = 1953525168;
          nicMembers = [
            "enp0s13f0u3"
            "enp0s13f0u4"
          ];
          nicMac = "9c:bf:0d:00:20:37";
          gpuPciId = "8086:9a49";
          address = "10.15.4.9";
        };
      };
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
            ./modules/fleet/base.nix
            ./modules/fleet/networking.nix
            ./modules/fleet/comin.nix
            ./installers/framework-iso.nix
          ];
        }).config.system.build.isoImage;
      mkPiImage =
        targetHost:
        (mkHost {
          system = "aarch64-linux";
          hostname = targetHost;
          modules = fleetModules ++ [
            comin.nixosModules.comin
            nixos-hardware.nixosModules.raspberry-pi-5
            (if targetHost == "observability-pi" then ./hosts/observability-pi else ./hosts/services-pi)
            {
              _module.args = {
                inherit targetHost;
                telemetryIdentity = null;
              };
              imports = [ ./installers/rpi-image.nix ];
            }
          ];
        }).config.system.build.sdImage;
    in
    {
      inherit nixosConfigurations;

      images = {
        observability-pi = mkPiImage "observability-pi";
        services-pi = mkPiImage "services-pi";
        framework-01 = mkFrameworkImage "framework-01";
        framework-02 = mkFrameworkImage "framework-02";
        framework-03 = mkFrameworkImage "framework-03";
      };

      lib.mkHost = mkHost;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = forAllSystems (system: {
        inherit (nixpkgs.legacyPackages.${system}) deadnix statix;
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
          inherit nixosConfigurations;
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
        };
        evaluation = import ./checks/evaluation.nix {
          inherit nixosConfigurations;
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
                "readiness:framework-01:insufficient-measured-free-space"
              ])
              (fixture ./checks/fixtures/missing-evidence.json [
                "readiness:no-evidence:backup-blocked"
                "readiness:no-evidence:restore-blocked"
              ])
              (fixture ./checks/fixtures/missing-hardware.json [
                "schema:framework-01:invalid-hardware-gpu"
                "schema:framework-01:invalid-hardware-installDisk"
                "schema:framework-01:invalid-hardware-nic"
              ])
              (fixture ./checks/fixtures/sysfs-hardware.json [
                "readiness:framework-01:free-bytes-blocked"
                "readiness:framework-01:installDisk-blocked"
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
