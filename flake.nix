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
    { nixpkgs, ... }:
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

      checks = forAllSystems (system: {
        evaluation = import ./checks/evaluation.nix {
          inherit nixosConfigurations;
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
        };
      });
    };
}
