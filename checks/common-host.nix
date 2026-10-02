{
  lib,
  nixosConfigurations,
  pkgs,
}:
let
  expectedAddresses = {
    observability-pi = "10.15.4.6/24";
    framework-01 = "10.15.4.5/24";
    framework-02 = "10.15.4.7/24";
    framework-03 = "10.15.4.9/24";
    services-pi = "10.15.4.4/24";
  };
  checkHost =
    hostname: address:
    let
      config = nixosConfigurations.${hostname}.config;
      comin = config.services.comin;
      networkAddresses = lib.flatten (
        lib.mapAttrsToList (_: network: network.address or [ ]) config.systemd.network.networks
      );
    in
    assert config.networking.hostName == hostname;
    assert builtins.elem address networkAddresses;
    assert config.services.openssh.enable;
    assert config.services.openssh.settings.PasswordAuthentication == false;
    assert config.services.openssh.settings.PermitRootLogin == "prohibit-password";
    assert config.services.journald.settings.Journal.Storage == "persistent";
    assert config.networking.firewall.enable;
    assert comin.enable;
    assert comin.debug == false;
    assert comin.exporter.port == 4243;
    assert comin.exporter.openFirewall == false;
    assert comin.sshAllowedSignersPath != null;
    assert lib.all (remote: remote.poller.period == 60) comin.remotes;
    assert lib.all (remote: remote.branches.main.operation == "switch") comin.remotes;
    assert lib.all (remote: remote.branches.testing.operation == "test") comin.remotes;
    assert lib.all (remote: remote.branches.testing.name == "testing-${hostname}") comin.remotes;
    true;
  allHostsValid = lib.all (hostname: checkHost hostname expectedAddresses.${hostname}) (
    builtins.attrNames expectedAddresses
  );
in
assert allHostsValid;
pkgs.runCommand "common-host" { } ''
  # Comin verifies signed commits before evaluation/deployment. This source-level
  # invariant complements option evaluation without requiring a nondeterministic remote.
  source=${nixosConfigurations.framework-01.config.services.comin.package.src}
  grep -q 'func commitSignedBySSH' "$source/internal/repository/git.go"
  grep -q 'if fetched.Verified' "$source/internal/manager/manager.go"
  # Failed evaluation/build paths continue before submission to the deployer,
  # preserving the active system generation.
  grep -q 'generation.EvalErr != ""' "$source/internal/manager/manager.go"
  grep -q 'generation.BuildErr == ""' "$source/internal/manager/manager.go"
  touch $out
''
