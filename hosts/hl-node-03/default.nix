{ lib, fleetTopology, ... }:
let
  nic = fleetTopology.nodes.hl-node-03.nic;
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
        sopsFile = ../../secrets/hosts/hl-node-03/bootstrap.yaml;
        mode = "0400";
        restartUnits = [ ];
      })
    // {
      vikunja-config-yml = {
        mode = lib.mkForce "0400";
        uid = lib.mkForce 1000;
      };
    };
  fleet.preparedApplications.existingSecretPaths = [
    "/run/secrets/tailscale-auth-key"
    "/run/secrets/restic-repository"
    "/run/secrets/restic-password"
    "/run/secrets/restic-s3-credentials"
  ];
  fleet.preparedApplications.secretsFile = ../../secrets/hosts/hl-node-03/applications.yaml;
  fleet.comin.enableMirror = false;
  services.fleet.forgejo-runner = {
    enable = true;
    uuid = "d590a8c1-c6d3-4fdc-b11f-6a57978e78ec";
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
        address = [ "10.15.4.7/24" ];
        routes = [ { Gateway = "10.15.4.1"; } ];
        networkConfig.DNS = [ "10.15.4.1" ];
      };
    };
  };
}
