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
    { self, nixpkgs, ... }:
    let
      mkHost = import ./lib/mk-host.nix { inherit nixpkgs; };
      nixosConfigurations = {
        observability-pi = mkHost {
          system = "aarch64-linux";
          hostname = "observability-pi";
          modules = [ ./hosts/observability-pi ];
        };
        framework-01 = mkHost {
          system = "x86_64-linux";
          hostname = "framework-01";
          modules = [ ./hosts/framework-01 ];
        };
        framework-02 = mkHost {
          system = "x86_64-linux";
          hostname = "framework-02";
          modules = [ ./hosts/framework-02 ];
        };
        framework-03 = mkHost {
          system = "x86_64-linux";
          hostname = "framework-03";
          modules = [ ./hosts/framework-03 ];
        };
        services-pi = mkHost {
          system = "aarch64-linux";
          hostname = "services-pi";
          modules = [ ./hosts/services-pi ];
        };
      };
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      inherit nixosConfigurations;

      lib.mkHost = mkHost;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = forAllSystems (system: {
        inherit (nixpkgs.legacyPackages.${system}) deadnix statix;
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
            ];
          in
          pkgs.runCommand "inventory-fixtures" { } ''
            ${nixpkgs.lib.concatMapStringsSep "\n" (test: "test -e ${test}") tests}
            touch $out
          '';
      });
    };
}
