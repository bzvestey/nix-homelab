{ pkgs, lib }:
let
  backups = import ../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  database =
    name: port: healthCheckCommand:
    let
      job = backups.database {
        inherit name port healthCheckCommand;
        package = pkgs.postgresql_18;
        user = "postgres-${name}";
        socket = "/run/postgres-${name}";
        dataPath = "/var/lib/postgres-${name}";
      };
    in
    job
    // {
      # Source database owners differ from app; retain the original restore remap.
      restoreCommand =
        lib.replaceStrings
          [ "--exit-on-error -d app" ]
          [ "--exit-on-error --no-owner --no-acl --role=app -d app" ]
          job.restoreCommand;
    };
}
