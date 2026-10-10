{
  lib,
  modulesPath,
  pkgs,
  disko,
  targetHost,
  targetSystem,
  diskById,
  diskModel,
  diskSerial,
  diskSectors,
  nicMembers,
  nicMac,
  nicPermanentMacs,
  address,
  gpuPciId,
  ...
}:
let
  installer = import ./framework-installer.nix {
    inherit
      lib
      pkgs
      targetHost
      targetSystem
      diskById
      diskModel
      diskSerial
      diskSectors
      nicMembers
      nicPermanentMacs
      gpuPciId
      ;
    diskoPackage = disko.packages.${pkgs.stdenv.hostPlatform.system}.disko;
  };
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];
  image.baseName = lib.mkForce "${targetHost}-bootstrap";
  environment.systemPackages = [ installer ];
  services.openssh.enable = true;
  networking.hostName = "${targetHost}-installer";
  # Minimal installation media enables NetworkManager; networkd owns these static links.
  networking.networkmanager.enable = lib.mkForce false;
  systemd.network = {
    netdevs."10-bond0" = {
      netdevConfig = {
        Kind = "bond";
        Name = "bond0";
        MACAddress = nicMac;
      };
      bondConfig = {
        Mode = "active-backup";
        MIIMonitorSec = "100ms";
      };
    };
    networks =
      lib.listToAttrs (
        lib.imap0 (index: member: {
          name = "10-member-${toString (index + 1)}";
          value = {
            matchConfig = {
              Name = member;
            }
            // (
              if nicPermanentMacs ? ${member} then
                { PermanentMACAddress = nicPermanentMacs.${member}; }
              else
                # Preserve unverified hosts' boot networking; their installer refuses.
                { MACAddress = nicMac; }
            );
            networkConfig.Bond = "bond0";
          };
        }) nicMembers
      )
      // {
        "20-bond0" = {
          matchConfig.Name = "bond0";
          address = [ "${address}/24" ];
          routes = [ { Gateway = "10.15.4.1"; } ];
          networkConfig.DNS = [ "10.15.4.1" ];
        };
      };
  };
  systemd.services."serial-getty@ttyS0".enable = lib.mkDefault true;
  boot.initrd.systemd = {
    enable = true;
    tpm2.enable = true;
  };
}
