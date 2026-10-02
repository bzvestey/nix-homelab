{ lib, pkgs, ... }:
{
  environment.systemPackages = [ (pkgs.callPackage ../../packages/fleet-enroll.nix { }) ];

  sops = {
    age.sshKeyPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
    validateSopsFiles = lib.mkDefault true;
  };
}
