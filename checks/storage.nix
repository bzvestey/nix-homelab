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
      imports = [ ../modules/fleet/storage.nix ];

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
    client.succeed("test $(cat /mnt/bulk/test/service-write) = mounted")
  '';
}
