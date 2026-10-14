{ pkgs, lib }:
rec {
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
      serviceUnit ? "podman-${name}.service",
      exclude ? [ ],
      sqliteDatabases ? [ ],
      online ? sqliteDatabases != [ ],
      healthCheckCommand,
    }:
    let
      validate =
        directory:
        lib.concatMapStringsSep "\n" (database: ''
          test "$(${pkgs.sqlite}/bin/sqlite3 -readonly "${directory}/state/${database}" 'PRAGMA integrity_check;')" = ok
        '') sqliteDatabases;
      exclusions = exclude ++ map (database: "/${database}*") sqliteDatabases;
    in
    {
      frequency = if online then "daily" else "*-*-* 06:00:00 America/Los_Angeles";
      interruptsService = !online;
      paths = [ path ];
      requiredPaths =
        if sqliteDatabases == [ ] then [ "state" ] else map (database: "state/${database}") sqliteDatabases;
      serviceUnits = [ serviceUnit ];
      createCommand =
        lib.optionalString (!online) ''
          unit=${lib.escapeShellArg serviceUnit}
          active=0
          if ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit"; then active=1; fi
          ${pkgs.systemd}/bin/systemctl stop "$unit"
          trap 'if [ "$active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start "$unit"; fi' EXIT
        ''
        + (
          if online then
            ''
              ${pkgs.coreutils}/bin/mkdir -p "$FLEET_BACKUP_STAGING_DIR/state"
              ${lib.concatMapStringsSep "\n" (database: ''
                ${pkgs.coreutils}/bin/mkdir -p "$FLEET_BACKUP_STAGING_DIR/state/${builtins.dirOf database}"
                ${pkgs.sqlite}/bin/sqlite3 -readonly ${lib.escapeShellArg "${path}/${database}"} \
                  ".timeout 60000" ".backup '$FLEET_BACKUP_STAGING_DIR/state/${database}'"
              '') sqliteDatabases}
              ${validate "$FLEET_BACKUP_STAGING_DIR"}
              # Assets are temporal copies, not atomic with the database snapshots.
              set +e
              ${pkgs.rsync}/bin/rsync -a ${
                lib.escapeShellArgs (map (pattern: "--exclude=${pattern}") exclusions)
              } \
                -- ${lib.escapeShellArg "${path}/"} "$FLEET_BACKUP_STAGING_DIR/state/"
              rc=$?
              set -e
              [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]
            ''
          else
            ''
              ${
                if exclude == [ ] then
                  "${pkgs.coreutils}/bin/cp -a --no-preserve=links ${lib.escapeShellArg path}"
                else
                  "${pkgs.rsync}/bin/rsync -a ${
                    lib.escapeShellArgs (map (pattern: "--exclude=${pattern}") exclude)
                  } -- ${lib.escapeShellArg "${path}/"}"
              } "$FLEET_BACKUP_STAGING_DIR/state"
            ''
        );
      rehearsalCommand = validate "$FLEET_RESTORE_SOURCE_DIR";
      restoreCommand = validate "$FLEET_RESTORE_SOURCE_DIR" + ''
        ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg path}
        ${pkgs.findutils}/bin/find ${lib.escapeShellArg path} -mindepth 1 -maxdepth 1 -exec ${pkgs.coreutils}/bin/rm -rf -- {} +
        ${pkgs.coreutils}/bin/cp -a "$FLEET_RESTORE_SOURCE_DIR/state/." ${lib.escapeShellArg path}
      '';
      inherit owner group healthCheckCommand;
    };
  tailscaleIdentity =
    { name, healthCheckCommand }:
    let
      path = "/var/lib/tailscale-${name}";
      job = state {
        name = "tailscale-${name}";
        inherit path healthCheckCommand;
        serviceUnit = "tailscale-${name}.service";
        online = true;
      };
      validate = directory: ''
        if ! ${pkgs.jq}/bin/jq -e '
          (.["_current-profile"] | @base64d) as $key |
          (.["_profiles"] | @base64d | fromjson) as $profiles |
          (.[$key] | @base64d | fromjson) as $prefs |
          ([$profiles[] | select(.Key == $key)]) as $matching |
          ($key | test("^profile-[a-f0-9]+$")) and
          ($matching | length == 1) and
          ($matching[0].ID == ($key | ltrimstr("profile-"))) and
          (.["_machinekey"] | @base64d | test("^privkey:[a-f0-9]{64}$")) and
          ($prefs.Config.PrivateNodeKey | test("^privkey:[a-f0-9]{64}$")) and
          ($prefs.Config.NodeID | type == "string" and length > 0) and
          ($prefs.Config.NodeID == $matching[0].NodeID) and
          ($prefs.WantRunning == true and $prefs.LoggedOut != true)
        ' "${directory}/state/tailscaled.state" >/dev/null 2>&1; then
          echo 'Invalid persisted Tailscale identity/profile linkage.' >&2
          exit 1
        fi
      '';
    in
    job
    // {
      mode = "0600";
      directoryMode = "0700";
      requiredPaths = [ "state/tailscaled.state" ];
      createCommand = ''
        # Tailnet Lock has separate authority state and needs its own contract.
        test ! -e ${path}/tka
        ${pkgs.coreutils}/bin/mkdir -p "$FLEET_BACKUP_STAGING_DIR/state"
        # FileStore atomically replaces this map. Open once to capture one
        # complete persisted version, not the mutable logs/certificate cache.
        ${pkgs.coreutils}/bin/cat ${path}/tailscaled.state >"$FLEET_BACKUP_STAGING_DIR/state/tailscaled.state"
        ${validate "$FLEET_BACKUP_STAGING_DIR"}
      '';
      rehearsalCommand = validate "$FLEET_RESTORE_SOURCE_DIR";
      restoreCommand = validate "$FLEET_RESTORE_SOURCE_DIR" + job.restoreCommand;
    };
}
