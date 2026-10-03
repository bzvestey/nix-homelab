{
  lib,
  nixosConfigurations,
  pkgs,
}:
let
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpx0yPdFPKUFBLn6OKJJAyqnlvoLmll4m97l/YMLu8 bryan@vestey.dev";
  exporterRule = ''
    ip saddr 10.15.4.6 tcp dport 4243 accept comment "observability comin scrape"

    ip saddr 10.15.4.6 tcp dport 9464 accept comment "observability agent scrape"
  '';
  observabilityRule = ''
    ip saddr 10.15.4.0/24 tcp dport { 4319, 4320 } accept comment "fleet OTLP gateway"

  '';
  remoteIdentity = remote: {
    inherit (remote) name url;
  };
  expectedRemotes = [
    {
      name = "github";
      url = "https://github.com/bzvestey/nix-homelab.git";
    }
    {
      name = "tangled";
      url = "https://tangled.org/bzvestey.minastas.social/nix-homelab";
    }
  ];
  expected = {
    observability-pi = {
      address = "10.15.4.6/24";
      networks."20-lan" = {
        Name = "end0";
        MACAddress = "2c:cf:67:72:a7:20";
      };
    };
    framework-01 = {
      address = "10.15.4.5/24";
      networks = {
        "10-member-1" = {
          Name = "enp0s13f0u1";
          MACAddress = "9c:bf:0d:00:23:fe";
        };
        "10-member-2" = {
          Name = "enp0s13f0u2";
          MACAddress = "9c:bf:0d:00:23:fe";
        };
        "20-bond0".Name = "bond0";
      };
    };
    framework-02 = {
      address = "10.15.4.7/24";
      networks = {
        "10-member-1" = {
          Name = "enp0s13f0u3";
          MACAddress = "9c:bf:0d:00:0d:3c";
        };
        "10-member-2" = {
          Name = "enp0s13f0u4";
          MACAddress = "9c:bf:0d:00:0d:3c";
        };
        "20-bond0".Name = "bond0";
      };
    };
    framework-03 = {
      address = "10.15.4.9/24";
      networks = {
        "10-member-1" = {
          Name = "enp0s13f0u3";
          MACAddress = "9c:bf:0d:00:20:37";
        };
        "10-member-2" = {
          Name = "enp0s13f0u4";
          MACAddress = "9c:bf:0d:00:20:37";
        };
        "20-bond0".Name = "bond0";
      };
    };
    services-pi = {
      address = "10.15.4.4/24";
      networks."20-lan" = {
        Name = "end0";
        MACAddress = "2c:cf:67:ed:27:ed";
      };
    };
  };
  checkHost =
    hostname: facts:
    let
      config = nixosConfigurations.${hostname}.config;
      comin = config.services.comin;
      networkAddresses = lib.flatten (
        lib.mapAttrsToList (_: network: network.address or [ ]) config.systemd.network.networks
      );
      selectorsValid = lib.all (
        name: config.systemd.network.networks.${name}.matchConfig == facts.networks.${name}
      ) (builtins.attrNames facts.networks);
      cominPolicyValid =
        comin.enable
        && comin.debug == false
        && comin.sshAllowedSignersPath == "/etc/comin/allowed_signers"
        && map remoteIdentity comin.remotes == expectedRemotes
        && lib.all (remote: remote.poller.period == 60) comin.remotes
        && lib.all (
          remote:
          remote.branches.main == {
            name = "main";
            operation = "switch";
          }
        ) comin.remotes
        && lib.all (
          remote:
          remote.branches.testing == {
            name = "testing-${hostname}";
            operation = "test";
          }
        ) comin.remotes
        && lib.all (
          remote: remote.auth.access_token_path == "" && remote.auth.ssh_deploy_key_path == ""
        ) comin.remotes
        &&
          comin.retention == {
            deployment_boot_entry_capacity = 3;
            deployment_successful_capacity = 3;
            deployment_any_capacity = 5;
          };
    in
    assert config.networking.hostName == hostname;
    assert networkAddresses == [ facts.address ];
    assert selectorsValid;
    assert config.services.openssh.enable;
    assert config.services.openssh.settings.PasswordAuthentication == false;
    assert config.services.openssh.settings.KbdInteractiveAuthentication == false;
    assert config.services.openssh.settings.PermitRootLogin == "prohibit-password";
    assert config.users.users.root.openssh.authorizedKeys.keys == [ adminKey ];
    assert config.services.journald.settings.Journal.Storage == "persistent";
    assert !(config.systemd.services ? observability-bootstrap-single-ethernet);
    assert config.networking.firewall.enable;
    assert config.networking.nftables.enable;
    assert !(builtins.elem 4243 config.networking.firewall.allowedTCPPorts);
    assert
      config.networking.firewall.extraInputRules
      == lib.optionalString (hostname == "observability-pi") observabilityRule + exporterRule;
    assert comin.exporter.listen_address == "0.0.0.0";
    assert comin.exporter.port == 4243;
    assert comin.exporter.openFirewall == false;
    assert cominPolicyValid;
    true;
  allHostsValid = lib.all (hostname: checkHost hostname expected.${hostname}) (
    builtins.attrNames expected
  );
  cominHost =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then "services-pi" else "framework-01";
  cominPackage = nixosConfigurations.${cominHost}.config.services.comin.package;
  cominExecutableTests = cominPackage.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./comin-prior-generation.patch ];
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      go test ./internal/repository -run 'Test(HeadSignedBy|UpdateGpg|UpdateSSHSigning)$'
      go test ./internal/manager -run 'Test(Build|RejectUnverifiedSSHCommits)$'
      runHook postCheck
    '';
  });
  wiredLink = import ../lib/wired-link.nix;
  piGuard = pkgs.replaceVars ../installers/destructive-device-guard.sh {
    bash = "${pkgs.bash}/bin/bash";
    devRoot = "/dev";
    sysDevBlock = "/sys/dev/block";
    readlink = "${pkgs.coreutils}/bin/readlink";
    stat = "${pkgs.coreutils}/bin/stat";
    logGuard = ":";
  };
  telemetryInitializer = import ../installers/telemetry-initializer.nix {
    inherit lib pkgs;
    targetHost = "observability-pi";
    telemetryIdentity = null;
  };
in
assert allHostsValid;
assert cominPackage.system == pkgs.stdenv.hostPlatform.system;
pkgs.runCommand "common-host" { } ''
  test -e ${cominExecutableTests}

  if printf 'observability-pi\n' | ${telemetryInitializer}/bin/initialize-telemetry-ssd >initializer-output 2>&1; then
    echo "initializer accepted unresolved telemetry identity" >&2
    exit 1
  fi
  grep -Fx 'refusing: expected device identity is unresolved' initializer-output
  ! grep -F 'Permission denied' initializer-output
  ! grep -F 'Type INITIALIZE TELEMETRY SSD' initializer-output
  ! grep -F 'About to create an ext4 filesystem' initializer-output
  ! grep -F 'mkfs' initializer-output

  if ${pkgs.bash}/bin/bash ${piGuard} observability-pi UNRESOLVED UNRESOLVED UNRESOLVED 0 observability-pi 2>guard-error; then
    echo "unresolved telemetry identity was accepted" >&2
    exit 1
  fi
  grep -Fx 'refusing: expected device identity is unresolved' guard-error
  ! grep -F 'Permission denied' guard-error

  test_selector() {
    expected="$1"
    fixture="$2"
    actual=$(SYS_CLASS_NET="$fixture" ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg wiredLink.selectScript})
    test "$actual" = "$expected"
  }

  fixture=$TMPDIR/links
  mkdir -p "$fixture"
  test_selector "" "$fixture"

  mkdir -p "$fixture/end0/device"
  echo 1 > "$fixture/end0/type"
  test_selector end0 "$fixture"

  mkdir -p "$fixture/wlan0/device" "$fixture/wlan0/wireless" "$fixture/veth0"
  echo 1 > "$fixture/wlan0/type"
  echo 1 > "$fixture/veth0/type"
  test_selector end0 "$fixture"

  mkdir -p "$fixture/eth1/device"
  echo 1 > "$fixture/eth1/type"
  test_selector $'end0\neth1' "$fixture"
  touch $out
''
