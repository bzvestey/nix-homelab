{ lib, fleetTopology, ... }:
let
  nic = fleetTopology.nodes.hl-node-04.nic;
in
{
  imports = [
    ./disk-config.nix
  ];
  hardware.enableRedistributableFirmware = true;
  sops.secrets =
    lib.genAttrs
      [
        "tailscale-auth-key"
        "restic-repository"
        "restic-password"
        "restic-s3-credentials"
      ]
      (_: {
        sopsFile = ../../secrets/hosts/hl-node-04/bootstrap.yaml;
        mode = "0400";
        restartUnits = [ ];
      });
  fleet.preparedApplications.existingSecretPaths = [
    "/run/secrets/tailscale-auth-key"
    "/run/secrets/restic-repository"
    "/run/secrets/restic-password"
    "/run/secrets/restic-s3-credentials"
  ];
  fleet.preparedApplications.secretsFile = ../../secrets/hosts/hl-node-04/applications.yaml;
  fleet.comin.enableMirror = false;
  services.fleet.forgejo-runner = {
    enable = true;
    uuid = "456e3c18-a5e5-4869-9906-a7d65d2eb2a2";
  };
  boot = {
    loader = {
      grub.enable = false;
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    initrd.systemd = {
      enable = true;
      tpm2.enable = true;
    };
  };
  systemd.network = {
    links = lib.mapAttrs' (
      member: mac:
      lib.nameValuePair "10-${member}" {
        matchConfig = {
          PermanentMACAddress = mac;
          Kind = "!*";
        };
        linkConfig = {
          Name = member;
          NamePolicy = "";
        };
      }
    ) nic.permanentMacAddresses;
    netdevs."10-bond0" = {
      netdevConfig = {
        Kind = "bond";
        Name = "bond0";
        MACAddress = nic.macAddress;
      };
      bondConfig = {
        Mode = "active-backup";
        MIIMonitorSec = "100ms";
      };
    };
    networks = {
      "10-member-1" = {
        matchConfig = {
          Name = "lan0";
          PermanentMACAddress = nic.permanentMacAddresses.lan0;
        };
        networkConfig.Bond = "bond0";
      };
      "10-member-2" = {
        matchConfig = {
          Name = "lan1";
          PermanentMACAddress = nic.permanentMacAddresses.lan1;
        };
        networkConfig.Bond = "bond0";
      };
      "20-bond0" = {
        matchConfig.Name = "bond0";
        address = [ "10.15.4.9/24" ];
        routes = [ { Gateway = "10.15.4.1"; } ];
        networkConfig.DNS = [ "10.15.4.1" ];
      };
    };
  };
}
