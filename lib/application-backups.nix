{ pkgs, lib }:
{
  database =
    {
      name,
      package,
      user,
      socket,
      port,
      dataPath,
      healthCheckCommand,
    }:
    let
      connection = "-h ${socket} -p ${toString port}";
      run = "${pkgs.util-linux}/bin/runuser -u ${user} --";
      validate = ''
        scratch="fleet_restore_${name}_$$"
        ${run} ${package}/bin/createdb ${connection} -T template0 --locale=C "$scratch"
        trap '${run} ${package}/bin/dropdb ${connection} --if-exists "$scratch"' EXIT
        ${run} ${package}/bin/pg_restore ${connection} --exit-on-error --no-owner --no-acl -d "$scratch" < "$FLEET_RESTORE_SOURCE_DIR/database.dump"
        ${run} ${package}/bin/dropdb ${connection} "$scratch"
        trap - EXIT
      '';
    in
    {
      frequency = "hourly";
      backupClass = "database";
      paths = [ dataPath ];
      owner = user;
      group = user;
      mode = "0600";
      directoryMode = "0700";
      requiredPaths = [ "database.dump" ];
      serviceUnits = [ "podman-${name}.service" ];
      preflightCommand = "${run} ${package}/bin/pg_isready ${connection}";
      createCommand = ''
        ${run} ${package}/bin/pg_dump ${connection} -Fc app > "$FLEET_BACKUP_STAGING_DIR/database.dump"
      '';
      restoreCommand = validate + ''
        ${run} ${package}/bin/dropdb ${connection} --if-exists app
        ${run} ${package}/bin/createdb ${connection} -O app -T template0 --locale=C app
        ${run} ${package}/bin/pg_restore ${connection} --exit-on-error -d app < "$FLEET_RESTORE_SOURCE_DIR/database.dump"
      '';
      rehearsalCommand = validate;
      inherit healthCheckCommand;
    };
  state =
    {
      name,
      path,
      owner ? "root",
      group ? "root",
      healthCheckCommand,
    }:
    {
      frequency = "daily";
      paths = [ path ];
      requiredPaths = [ "state" ];
      serviceUnits = [ "podman-${name}.service" ];
      createCommand = ''
        active=0
        if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-${name}.service; then active=1; fi
        ${pkgs.systemd}/bin/systemctl stop podman-${name}.service
        trap 'if [ "$active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start podman-${name}.service; fi' EXIT
        ${pkgs.coreutils}/bin/cp -a ${lib.escapeShellArg path} "$FLEET_BACKUP_STAGING_DIR/state"
      '';
      restoreCommand = ''
        ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg path}
        ${pkgs.findutils}/bin/find ${lib.escapeShellArg path} -mindepth 1 -maxdepth 1 -exec ${pkgs.coreutils}/bin/rm -rf -- {} +
        ${pkgs.coreutils}/bin/cp -a "$FLEET_RESTORE_SOURCE_DIR/state/." ${lib.escapeShellArg path}
      '';
      inherit owner group healthCheckCommand;
    };
}
