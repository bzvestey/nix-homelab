{ lib, pkgs, ... }:
{
  environment.systemPackages = [ (pkgs.callPackage ../../packages/fleet-enroll.nix { }) ];

  sops = {
    age.sshKeyPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];
    validateSopsFiles = lib.mkDefault true;
  };

  # NixOS activation normally records snippet failures but continues as far as
  # replacing /run/current-system. A decryption failure must leave the prior
  # reachable generation selected instead.
  system.activationScripts.setupSecrets.text = lib.mkAfter ''
    if [ -e /run/current-system ] && (( _localstatus > 0 )); then
      exit "$_localstatus"
    fi
  '';
}
