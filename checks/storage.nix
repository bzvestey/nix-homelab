{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "fail-closed-nfs-storage";

  nodes = {
    server = _: {
      services.nfs.server = {
        enable = true;
        exports = "/srv/export 192.168.1.0/24(rw,no_subtree_check,no_root_squash,insecure)";
      };
      systemd.tmpfiles.rules = [ "d /srv/export 0777 root root -" ];
      networking.firewall.allowedTCPPorts = [ 2049 ];
      networking.firewall.allowedUDPPorts = [ 2049 ];
    };

    client = { ... }: {
      imports = [
        ../modules/fleet/podman.nix
        ../modules/fleet/storage.nix
      ];

      users = {
        groups.fixture.gid = 1000;
        users.fixture = {
          isSystemUser = true;
          uid = 1000;
          group = "fixture";
        };
      };

      fleet.storage.nfsMounts.test = {
        source = "server:/srv/export";
        target = "/mnt/bulk/test";
        dependentUnits = [ "storage-fixture" ];
      };
      fleet.storage.nfsMounts.escaped = {
        source = "server:/srv/export";
        target = "/mnt/bulk/test#data";
        dependentUnits = [ "storage-fixture" ];
      };
      systemd.services.storage-fixture = {
        wantedBy = [ "storage-test.target" ];
        serviceConfig = {
          User = "fixture";
          Group = "fixture";
          ExecStart = "${pkgs.writeShellScript "storage-fixture" ''
            set -eu
            printf mounted > /mnt/bulk/test/service-write
            exec ${pkgs.coreutils}/bin/sleep infinity
          ''}";
        };
      };
    };
  };

  testScript = ''
    start_all()
    server.wait_for_unit("multi-user.target")
    client.wait_for_unit("multi-user.target")

    # NixOS's canonical path escaping must also drive dependencies, including
    # when several mounts contribute settings to the same dependent unit.
    client.succeed("systemctl cat 'mnt-bulk-test\\x23data.mount'")
    client.succeed("systemctl cat storage-fixture.service | grep -F 'After=mnt-bulk-test.mount mnt-bulk-test\\x23data.mount'")
    client.succeed("systemctl cat storage-fixture.service | grep -F 'BindsTo=mnt-bulk-test.mount mnt-bulk-test\\x23data.mount'")

    # Cleanup is timer-driven and can only prune old images, never other
    # Podman resources through the broad `system prune` command.
    client.succeed("systemctl is-enabled podman-image-prune.timer | grep -Fx enabled")
    client.succeed("systemctl cat podman-image-prune.service | grep -F 'podman image prune --force --filter until=720h'")
    client.fail("systemctl cat podman-image-prune.service | grep -F 'podman system prune'")
    client.succeed("test \"$(systemctl is-enabled podman-prune.service || true)\" = masked")
    client.succeed("test \"$(systemctl is-enabled podman-prune.timer || true)\" = masked")
    client.fail("systemctl cat podman-prune.service | grep -F 'podman system prune'")

    # Observe the real underlying directory, not the automount facade.
    client.succeed("systemctl stop mnt-bulk-test.automount")
    client.succeed("test $(stat -c %U:%G /mnt/bulk/test) = root:root")
    client.fail("runuser -u fixture -- touch /mnt/bulk/test/bare-write")

    server.succeed("systemctl stop nfs-server.service")
    client.succeed("systemctl start mnt-bulk-test.automount")
    client.fail("systemctl start storage-fixture.service")
    client.fail("systemctl is-active storage-fixture.service")

    server.succeed("systemctl start nfs-server.service")
    client.succeed("systemctl reset-failed mnt-bulk-test.mount")
    client.succeed("systemctl reset-failed 'mnt-bulk-test\\x23data.mount'")
    client.succeed("systemctl start storage-fixture.service")
    client.wait_until_succeeds("test $(cat /mnt/bulk/test/service-write) = mounted")

    # A normal (non-lazy) unmount must propagate to the dependent service.
    client.succeed("systemctl stop mnt-bulk-test.mount")
    client.wait_until_fails("systemctl is-active storage-fixture.service")
    client.succeed("systemctl stop mnt-bulk-test.automount")
    client.fail("runuser -u fixture -- touch /mnt/bulk/test/outage-write")

    client.succeed("systemctl start mnt-bulk-test.automount")
    client.succeed("systemctl start storage-fixture.service")
    client.wait_until_succeeds("systemctl is-active storage-fixture.service")
    client.wait_until_succeeds("test $(cat /mnt/bulk/test/service-write) = mounted")
  '';
}
