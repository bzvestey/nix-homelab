{ lib, fleetTopology, ... }:
let
  nic = fleetTopology.nodes.hl-node-04.nic;
in
{
  imports = [
    ./disk-config.nix
  ];
  hardware.enableRedistributableFirmware = true;
  services.fleet.forgejo-runner = {
    enable = true;
    uuid = "e9842b40-7feb-4fe9-b81c-4ebed7016304";
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
