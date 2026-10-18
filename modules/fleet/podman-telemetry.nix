{
  config,
  lib,
  pkgs,
  ...
}:
let
  names = builtins.attrNames config.virtualisation.oci-containers.containers;
in
{
  config =
    lib.mkIf (config.fleet.telemetry.enable && config.virtualisation.podman.enable && names != [ ])
      {
        systemd.services.podman-telemetry = {
          description = "Collect managed Podman container state without container IDs";
          path = [
            pkgs.podman
            pkgs.jq
            pkgs.coreutils
          ];
          script = ''
            set -euo pipefail
            directory=/var/lib/node_exporter/textfile_collector
            state=$(mktemp)
            output=$(mktemp "$directory/.podman.XXXXXX")
            trap 'rm -f "$state" "$output"' EXIT
            for metric in fleet_podman_container_present fleet_podman_container_running fleet_podman_collection_success fleet_podman_collection_timestamp_seconds; do
              echo "# TYPE $metric gauge"
            done > "$output"
            if podman ps --all --format json > "$state"; then
              jq -nr --argjson names ${lib.escapeShellArg (builtins.toJSON names)} --slurpfile data "$state" '
                $names[] as $name |
                [$data[0][] | select(.Names | index($name))] as $matches |
                "fleet_podman_container_present{container=\($name | tojson)} \($matches | length | if . > 0 then 1 else 0 end)",
                "fleet_podman_container_running{container=\($name | tojson)} \(if any($matches[]; .State == "running") then 1 else 0 end)"
              ' >> "$output"
              echo 'fleet_podman_collection_success 1' >> "$output"
            else
              echo 'fleet_podman_collection_success 0' >> "$output"
            fi
            echo "fleet_podman_collection_timestamp_seconds $(date +%s)" >> "$output"
            chmod 0644 "$output"
            mv "$output" "$directory/podman.prom"
          '';
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            TimeoutStartSec = "20s";
            NoNewPrivileges = true;
            ProtectSystem = "full";
            ProtectHome = true;
            PrivateTmp = true;
          };
        };
        systemd.timers.podman-telemetry = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "30s";
          };
        };
      };
}
