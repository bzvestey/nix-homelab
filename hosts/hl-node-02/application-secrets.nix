{
  config,
  lib,
  hlNode02ApplicationSecretsFile,
  ...
}:
{
  sops.secrets =
    lib.mapAttrs
      (_: path: {
        sopsFile = hlNode02ApplicationSecretsFile;
        inherit path;
        owner = "root";
        group = "root";
        mode = "0600";
        restartUnits = [ ];
      })
      {
        immich-env = "/run/secrets/immich.env";
        mealie-env = "/run/secrets/mealie.env";
        tuwunel-config = "/run/secrets/tuwunel.toml";
        restic-repository = "/run/secrets/restic-repository";
        restic-password = "/run/secrets/restic-password";
        restic-s3-credentials = "/run/secrets/restic-s3-credentials";
      };

  fleet.backup.s3CredentialsFile = config.sops.secrets.restic-s3-credentials.path;
}
