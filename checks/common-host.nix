{
  cominPackageFor,
  lib,
  nixosConfigurations,
  piImageConfigurations,
  piPkgs,
  pkgs,
  telemetryInitializerPackage,
  telemetryIdentities,
}:
let
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMpx0yPdFPKUFBLn6OKJJAyqnlvoLmll4m97l/YMLu8 bryan@vestey.dev";
  exporterRule = ''
    ip saddr 10.15.4.6 tcp dport 4243 accept comment "observability comin scrape"

    ip saddr 10.15.4.6 tcp dport 9464 accept comment "observability agent scrape"
  '';
  applicationExporterRule = ''
    ip saddr 10.15.4.6 tcp dport 4243 accept comment "observability comin scrape"

    iifname "bond0" ip saddr { 10.15.4.4, 10.15.4.6 } tcp dport 8080 accept comment "cloudflared origins"

    iifname "tailscale0" tcp dport 443 accept comment "tailnet Caddy"


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
    hl-node-00 = {
      address = "10.15.4.6/24";
      networks."20-lan" = {
        Name = "end0";
        MACAddress = "2c:cf:67:72:a7:20";
      };
    };
    hl-node-02 = {
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
    hl-node-03 = {
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
    hl-node-04 = {
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
    hl-node-01 = {
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
        &&
          map remoteIdentity comin.remotes
          == (if hostname == "hl-node-02" then lib.take 1 expectedRemotes else expectedRemotes)
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
    assert config.networking.hosts."10.15.4.6" == [ "observability" ];
    assert networkAddresses == [ facts.address ];
    assert selectorsValid;
    assert config.services.openssh.enable;
    assert config.services.openssh.settings.PasswordAuthentication == false;
    assert config.services.openssh.settings.KbdInteractiveAuthentication == false;
    assert config.services.openssh.settings.PermitRootLogin == "prohibit-password";
    assert config.users.users.root.openssh.authorizedKeys.keys == [ adminKey ];
    assert config.services.journald.settings.Journal.Storage == "persistent";
    assert !(config.systemd.services ? observability-bootstrap-single-ethernet);
    assert
      hostname != "hl-node-00"
      || config.sops.secrets."cloudflared-tunnel.json".path == "/run/secrets/cloudflared-tunnel.json";
    assert
      hostname != "hl-node-00"
      ||
        config.sops.secrets."cloudflared-tunnel.json".sopsFile == ../secrets/pi-connectors/cloudflared.yaml;
    assert
      hostname != "hl-node-00"
      ||
        lib.all
          (
            name:
            config.sops.secrets.${name}.sopsFile == ../secrets/hosts/hl-node-00/bootstrap.yaml
            && config.sops.secrets.${name}.path == "/run/secrets/${name}"
            && config.sops.secrets.${name}.mode == "0400"
            && config.sops.secrets.${name}.owner == null
            && config.sops.secrets.${name}.uid == 0
          )
          [
            "tailscale-auth-key"
            "restic-repository"
            "restic-password"
            "restic-s3-credentials"
          ];
    assert
      hostname != "hl-node-00"
      || config.fleet.backup.s3CredentialsFile == "/run/secrets/restic-s3-credentials";
    assert hostname != "hl-node-01" || !(config.sops.secrets ? "cloudflared-tunnel.json");
    assert config.networking.firewall.enable;
    assert config.networking.nftables.enable;
    assert !(builtins.elem 4243 config.networking.firewall.allowedTCPPorts);
    assert
      config.networking.firewall.extraInputRules == (
        if hostname == "hl-node-02" then
          applicationExporterRule
        else
          lib.optionalString (hostname == "hl-node-00") observabilityRule + exporterRule
      );
    assert comin.exporter.listen_address == "0.0.0.0";
    assert comin.exporter.port == 4243;
    assert comin.exporter.openFirewall == false;
    assert config.fleet.telemetry.gatewayEndpoint == "http://observability:4320";
    assert cominPolicyValid;
    true;
  allHostsValid = lib.all (hostname: checkHost hostname expected.${hostname}) (
    builtins.attrNames expected
  );
  allHostsUseCorrectedComin = lib.all (
    hostName:
    let
      package = nixosConfigurations.${hostName}.config.services.comin.package;
    in
    package.drvPath == (cominPackageFor package.system).drvPath
  ) (builtins.attrNames nixosConfigurations);
  allPiImagesUseCorrectedComin = lib.all (
    hostName:
    piImageConfigurations.${hostName}.config.services.comin.package.drvPath
    == (cominPackageFor "aarch64-linux").drvPath
  ) (builtins.attrNames piImageConfigurations);
  telemetryIdentityWiringValid =
    telemetryIdentities == {
      hl-node-00 = {
        byId = "/dev/disk/by-id/ata-Samsung_SSD_970_EVO_Plus_2TB_S6S2NS0W226715A";
        model = "Samsung SSD 970 EVO Plus 2TB";
        serial = "S6S2NS0W226715A";
        sectors = 3907029168;
      };
      hl-node-01 = null;
    };
  cominHost =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then "hl-node-01" else "hl-node-02";
  deployedCominPackage = nixosConfigurations.${cominHost}.config.services.comin.package;
  cominExecutableTests = deployedCominPackage.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./comin-jj-change-id.patch
      ./comin-prior-generation.patch
    ];
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      go test ./internal/repository -run 'Test(HeadSignedBy|JujutsuChangeIDCommitSignedBySSH|UpdateGpg|UpdateSSHSigning)$'
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
    tr = "${pkgs.coreutils}/bin/tr";
    lsblk = "${pkgs.util-linux}/bin/lsblk";
    logGuard = ":";
  };
  bridgeGuardTool = pkgs.writeShellScript "bridge-guard-tool" ''
    set -euo pipefail
    state=/build/bridge-guard
    name=''${0##*fixture-}
    echo "$name:$*" >> "$state/log"
    case "$name" in
      readlink) echo "$state/dev/sda" ;;
      stat) echo '8 0' ;;
      tr)
        [ ! -e "$state/read-fails" ] || exit 3
        cat
        ;;
      lsblk)
        touch "$state/lsblk-called"
        raw=false
        column=
        for arg in "$@"; do
          case "$arg" in
            --raw | -[!-]*r*) raw=true ;;
            MODEL | SERIAL) column="$arg" ;;
          esac
        done
        case "$column:$raw" in
          MODEL:true) sed 's/ /\\x20/g' "$state/fallback-model" ;;
          MODEL:false) cat "$state/fallback-model" ;;
          SERIAL:*) cat "$state/fallback-serial" ;;
          *) exit 2 ;;
        esac
        ;;
      mkfs.ext4) touch "$state/mkfs-called" ;;
    esac
  '';
  bridgeGuardToolFor =
    name: pkgs.runCommand "bridge-fixture-${name}" { } ''ln -s ${bridgeGuardTool} "$out"'';
  fixtureSystemd = pkgs.writeShellScriptBin "udevadm" "exit 0";
  bridgeGuard = pkgs.replaceVars ../installers/destructive-device-guard.sh {
    bash = "${pkgs.bash}/bin/bash";
    devRoot = "/build/bridge-guard/dev";
    sysDevBlock = "/build/bridge-guard/sys/dev/block";
    readlink = bridgeGuardToolFor "readlink";
    stat = bridgeGuardToolFor "stat";
    tr = bridgeGuardToolFor "tr";
    lsblk = bridgeGuardToolFor "lsblk";
    logGuard = ":";
  };
  resolvedTelemetryInitializer = import ../installers/telemetry-initializer.nix {
    inherit lib pkgs;
    targetHost = "hl-node-00";
    telemetryIdentity = {
      byId = "/build/bridge-guard/dev/disk/by-id/ata-Samsung";
      model = "Samsung SSD 970 EVO Plus 2TB";
      serial = "S6S2NS0W226715A";
      sectors = 3907029168;
    };
    deviceGuard = bridgeGuard;
    mkfsExt4 = bridgeGuardToolFor "mkfs.ext4";
  };
  filesystemTelemetryInitializer = import ../installers/telemetry-initializer.nix {
    inherit lib;
    pkgs = pkgs // {
      systemd = fixtureSystemd;
    };
    targetHost = "hl-node-00";
    telemetryIdentity = {
      byId = "/build/bridge-guard/dev/disk/by-id/ata-Samsung";
      model = "Samsung SSD 970 EVO Plus 2TB";
      serial = "S6S2NS0W226715A";
      sectors = 3907029168;
    };
    deviceGuard = bridgeGuard;
  };
  initializerMismatchExpect = pkgs.writeText "initializer-mismatch.exp" ''
    set initializer [lindex $argv 0]
    set mismatch [lindex $argv 1]
    spawn -noecho $initializer
    expect -exact "Type hl-node-00 to authorize telemetry SSD initialization: "
    send -- "hl-node-00\rINITIALIZE TELEMETRY SSD\r"
    expect eof
    set status [lindex [wait] 3]
    if {$status == 0} {
      puts stderr "initializer accepted bridge fallback mismatched $mismatch"
      exit 1
    }
  '';
  initializerSuccessExpect = pkgs.writeText "initializer-success.exp" ''
    set initializer [lindex $argv 0]
    spawn -noecho $initializer
    expect -exact "Type hl-node-00 to authorize telemetry SSD initialization: "
    send -- "hl-node-00\r"
    expect -exact "Type INITIALIZE TELEMETRY SSD: "
    send -- "INITIALIZE TELEMETRY SSD\r"
    expect eof
    set status [lindex [wait] 3]
    if {$status != 0} {
      puts stderr "initializer failed with status $status"
      exit 1
    }
  '';
  telemetryInitializer = import ../installers/telemetry-initializer.nix {
    inherit lib pkgs;
    targetHost = "hl-node-00";
    telemetryIdentity = null;
  };
  expectedTelemetryInitializer = import ../installers/telemetry-initializer.nix {
    inherit lib;
    pkgs = piPkgs;
    targetHost = "hl-node-00";
    telemetryIdentity = telemetryIdentities.hl-node-00;
  };
  imageTelemetryInitializers =
    hostName:
    lib.filter (
      package: lib.getName package == "initialize-telemetry-ssd"
    ) piImageConfigurations.${hostName}.config.environment.systemPackages;
  productionTelemetryWiringValid =
    map (package: package.drvPath) (imageTelemetryInitializers "hl-node-00")
    == [ expectedTelemetryInitializer.drvPath ]
    && telemetryInitializerPackage.drvPath == expectedTelemetryInitializer.drvPath
    && imageTelemetryInitializers "hl-node-01" == [ ];
in
assert allHostsValid;
assert allHostsUseCorrectedComin;
assert allPiImagesUseCorrectedComin;
assert telemetryIdentityWiringValid;
assert productionTelemetryWiringValid;
assert deployedCominPackage.system == pkgs.stdenv.hostPlatform.system;
pkgs.runCommand "common-host" { nativeBuildInputs = [ pkgs.expect ]; } ''
  test -e ${cominExecutableTests}

  if printf 'hl-node-00\n' | ${telemetryInitializer}/bin/initialize-telemetry-ssd >initializer-output 2>&1; then
    echo "initializer accepted unresolved telemetry identity" >&2
    exit 1
  fi
  grep -Fx 'refusing: expected device identity is unresolved' initializer-output
  ! grep -F 'Permission denied' initializer-output
  ! grep -F 'Type INITIALIZE TELEMETRY SSD' initializer-output
  ! grep -F 'About to create an ext4 filesystem' initializer-output
  ! grep -F 'mkfs' initializer-output

  if ${pkgs.bash}/bin/bash ${piGuard} hl-node-00 UNRESOLVED UNRESOLVED UNRESOLVED 0 hl-node-00 2>guard-error; then
    echo "unresolved telemetry identity was accepted" >&2
    exit 1
  fi
  grep -Fx 'refusing: expected device identity is unresolved' guard-error
  ! grep -F 'Permission denied' guard-error

  bridge=/build/bridge-guard
  mkdir -p "$bridge/dev/disk/by-id" "$bridge/dev" "$bridge/sys/dev/block/8:0/device"
  touch "$bridge/dev/disk/by-id/ata-Samsung" "$bridge/dev/sda"
  printf '                \n' > "$bridge/sys/dev/block/8:0/device/model"
  printf '3907029168\n' > "$bridge/sys/dev/block/8:0/size"
  printf 'Samsung SSD 970 EVO Plus 2TB\n' > "$bridge/fallback-model"
  printf 'S6S2NS0W226715A\n' > "$bridge/fallback-serial"
  : > "$bridge/log"
  ${pkgs.bash}/bin/bash ${bridgeGuard} hl-node-00 "$bridge/dev/disk/by-id/ata-Samsung" \
    'Samsung SSD 970 EVO Plus 2TB' S6S2NS0W226715A 3907029168 hl-node-00 >/dev/null
  grep -Fx 'lsblk:-dno MODEL -- /build/bridge-guard/dev/sda' "$bridge/log"
  grep -Fx 'lsblk:-dno SERIAL -- /build/bridge-guard/dev/sda' "$bridge/log"

  truncate -s 64M "$bridge/dev/sda"
  expect ${initializerSuccessExpect} \
    ${filesystemTelemetryInitializer}/bin/initialize-telemetry-ssd | tee initializer-transcript
  ${pkgs.e2fsprogs}/bin/tune2fs -l "$bridge/dev/sda" >filesystem-features
  grep '^Filesystem features:.*project' filesystem-features
  grep '^Filesystem features:.*quota' filesystem-features

  touch "$bridge/read-fails"
  rm -f "$bridge/lsblk-called"
  if ${pkgs.bash}/bin/bash ${bridgeGuard} hl-node-00 "$bridge/dev/disk/by-id/ata-Samsung" \
    'Samsung SSD 970 EVO Plus 2TB' S6S2NS0W226715A 3907029168 hl-node-00 2>bridge-error; then
    echo "bridge guard accepted a failed readable sysfs fact" >&2
    exit 1
  fi
  grep -Fx 'refusing: device facts are incomplete' bridge-error
  test ! -e "$bridge/lsblk-called"
  rm "$bridge/read-fails"

  for mismatch in model serial; do
    printf 'Samsung SSD 970 EVO Plus 2TB\n' > "$bridge/fallback-model"
    printf 'S6S2NS0W226715A\n' > "$bridge/fallback-serial"
    printf 'WRONG\n' > "$bridge/fallback-$mismatch"
    : > "$bridge/log"
    if ${pkgs.bash}/bin/bash ${bridgeGuard} hl-node-00 "$bridge/dev/disk/by-id/ata-Samsung" \
      'Samsung SSD 970 EVO Plus 2TB' S6S2NS0W226715A 3907029168 hl-node-00 2>bridge-error; then
      echo "bridge fallback accepted mismatched $mismatch" >&2
      exit 1
    fi
    grep -Fx "$mismatch mismatch" < <(sed 's/^refusing: //' bridge-error)

    rm -f "$bridge/mkfs-called"
    expect ${initializerMismatchExpect} \
      ${resolvedTelemetryInitializer}/bin/initialize-telemetry-ssd "$mismatch" >initializer-transcript
    tr -d '\r' <initializer-transcript >initializer-output
    grep -F 'Type hl-node-00 to authorize telemetry SSD initialization: ' initializer-output
    grep -Fx "refusing: $mismatch mismatch" initializer-output
    ! grep -F 'Type INITIALIZE TELEMETRY SSD' initializer-output
    test ! -e "$bridge/mkfs-called"
  done

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
