_: {
  imports = [ ../services/storage-applications.nix ];
  services.fleet.storageApplications.enable = true;
  fleet.preparedApplications.enable = true;
  fleet.telemetry.enable = true;
}
