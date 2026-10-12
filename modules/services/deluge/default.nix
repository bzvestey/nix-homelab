{
  config,
  lib,
  pkgs,
  ...
}:
let
  backups = import ../../../lib/application-backups.nix { inherit pkgs lib; };
in
{
  options.services.fleet.deluge.enable =
    lib.mkEnableOption "Deluge with fail-closed Gluetun VPN and port manager";
  config = lib.mkIf config.services.fleet.deluge.enable {
    virtualisation.oci-containers = {
      backend = "podman";
      containers = {
        deluge = {
          image = "docker.io/linuxserver/deluge@sha256:9505c64720afa9e5f0ac1576e660dd6d1e9d4a6733b791f4821e8f496f19f41f";
          environmentFiles = [ "/run/secrets/deluge.env" ];
          environment = {
            PUID = "1000";
            PGID = "1000";
            TZ = "America/Los_Angeles";
            DELUGE_LOGLEVEL = "error";
          };
          volumes = [
            "/var/lib/media-automation/deluge:/config"
            "/mnt/bulk/videos:/videos"
            "/mnt/bulk/deluge-downloads:/downloads"
          ];
          extraOptions = [ "--network=container:gluetun" ];
          dependsOn = [ "gluetun" ];
        };
        gluetun = {
          image = "docker.io/qmcgaw/gluetun@sha256:1a5bf4b4820a879cdf8d93d7ef0d2d963af56670c9ebff8981860b6804ebc8ab";
          environmentFiles = [ "/run/secrets/gluetun.env" ];
          environment = {
            VPN_SERVICE_PROVIDER = "protonvpn";
            VPN_TYPE = "wireguard";
            SERVER_COUNTRIES = "Switzerland,Netherlands,Norway,Turkey,Iceland,Czech Republic";
            PORT_FORWARD_ONLY = "on";
            VPN_PORT_FORWARDING = "on";
            UPDATER_PERIOD = "24h";
            FIREWALL = "on";
            FIREWALL_INPUT_PORTS = "8112,58846";
          };
          ports = [
            "127.0.0.1:8112:8112"
            "127.0.0.1:58846:58846"
          ];
          volumes = [ "/run/media-automation/gluetun:/tmp/gluetun" ];
          extraOptions = [
            "--cap-add=NET_ADMIN"
            "--device=/dev/net/tun:/dev/net/tun"
          ];
        };
        deluge-port-manager = {
          image = "docker.io/plaexmstr/gluetun-deluge-port-manager@sha256:add2cdcd60d98dc96326fa61a58d331d77266610e73768ad0e0cfe499248a25c";
          environmentFiles = [ "/run/secrets/deluge-port-manager.env" ];
          environment = {
            DELUGE_SERVER = "localhost";
            DELUGE_PORT = "8112";
            PORT_FORWARDED = "/tmp/gluetun/forwarded_port";
          };
          volumes = [ "/run/media-automation/gluetun:/tmp/gluetun:ro" ];
          extraOptions = [ "--network=container:gluetun" ];
          dependsOn = [
            "gluetun"
            "deluge"
          ];
        };
      };
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/media-automation/deluge 0700 1000 1000 -"
      "d /run/media-automation/gluetun 0700 root root -"
    ];
    systemd.services = {
      podman-gluetun.unitConfig.ConditionPathIsReadable = "/run/secrets/gluetun.env";
      podman-deluge = {
        unitConfig.ConditionPathIsReadable = "/run/secrets/deluge.env";
        bindsTo = [ "podman-gluetun.service" ];
        after = [ "podman-gluetun.service" ];
        partOf = [ "podman-gluetun.service" ];
      };
      podman-deluge-port-manager = {
        unitConfig.ConditionPathIsReadable = "/run/secrets/deluge-port-manager.env";
        bindsTo = [
          "podman-gluetun.service"
          "podman-deluge.service"
        ];
        after = [
          "podman-gluetun.service"
          "podman-deluge.service"
        ];
        partOf = [
          "podman-gluetun.service"
          "podman-deluge.service"
        ];
      };
    };
    fleet = {
      storage.nfsMounts = {
        videos = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/videos";
          target = "/mnt/bulk/videos";
          dependentUnits = [ "podman-deluge" ];
        };
        deluge-downloads = {
          source = "nas.tailbc181.ts.net:/mnt/spinners-1/kube-store/deluge/downloads";
          target = "/mnt/bulk/deluge-downloads";
          dependentUnits = [ "podman-deluge" ];
        };
      };
      ingress.routes = [
        {
          hostname = "deluge.tailbc181.ts.net";
          upstream = "http://127.0.0.1:8112";
          exposure = "tailnet";
        }
      ];
      backup.jobs.deluge-state =
        (backups.state {
          name = "deluge";
          path = "/var/lib/media-automation/deluge";
          owner = "1000";
          group = "1000";
          healthCheckCommand = "${pkgs.curl}/bin/curl --fail --max-time 10 --retry 60 --retry-all-errors --retry-delay 1 http://127.0.0.1:8112/";
        })
        // {
          frequency = "hourly";
          backupClass = "database";
          mode = "0600";
          directoryMode = "0700";
          serviceUnits = [
            "podman-deluge.service"
            "podman-deluge-port-manager.service"
          ];
          # Stop the forwarding writer first; restart only units previously active.
          createCommand = ''
            deluge_active=0; sidecar_active=0
            if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-deluge; then deluge_active=1; fi
            if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-deluge-port-manager; then sidecar_active=1; fi
            trap 'if [ "$deluge_active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start podman-deluge; fi; if [ "$sidecar_active" = 1 ]; then ${pkgs.systemd}/bin/systemctl start podman-deluge-port-manager; fi' EXIT
            ${pkgs.systemd}/bin/systemctl stop podman-deluge-port-manager podman-deluge
            ${pkgs.coreutils}/bin/cp -a /var/lib/media-automation/deluge "$FLEET_BACKUP_STAGING_DIR/state"
          '';
        };
    };
  };
}
