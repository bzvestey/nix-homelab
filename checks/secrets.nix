{
  pkgs,
  sops-nix,
  comin,
  fleetEnroll,
}:
let
  enrollment = pkgs.runCommand "fleet-enroll-tests" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p etc/ssh
    ssh-keygen -q -t ed25519 -N "" -C vm-test -f etc/ssh/ssh_host_ed25519_key

    if HOST_KEY_PATH=$PWD/missing HOST_NAME=test-host ${fleetEnroll}/bin/fleet-enroll >missing.out 2>missing.err; then
      echo "fleet-enroll accepted a missing host key" >&2
      exit 1
    fi
    grep -F 'missing SSH host public key' missing.err

    HOST_KEY_PATH=$PWD/etc/ssh/ssh_host_ed25519_key.pub HOST_NAME=test-host \
      ${fleetEnroll}/bin/fleet-enroll >enrollment.out
    grep -F "$(cat etc/ssh/ssh_host_ed25519_key.pub)" enrollment.out
    recipient=$(${pkgs.ssh-to-age}/bin/ssh-to-age <etc/ssh/ssh_host_ed25519_key.pub)
    grep -F "$recipient" enrollment.out
    grep -F '&test-host' enrollment.out
    if grep -F 'PRIVATE KEY' enrollment.out; then
      echo "fleet-enroll printed private key material" >&2
      exit 1
    fi
    touch $out
  '';

  vm = pkgs.testers.runNixOSTest {
    name = "secrets";
    nodes.machine =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          sops-nix.nixosModules.sops
          comin.nixosModules.comin
          ../modules/fleet/secrets.nix
        ];

        services = {
          openssh.enable = true;
          comin = {
            enable = true;
            remotes = [ ];
          };
        };
        systemd.services.comin.serviceConfig.ExecStart = lib.mkForce "${pkgs.coreutils}/bin/sleep infinity";

        users.groups.secret-reader = { };
        users.users.secret-reader = {
          isSystemUser = true;
          group = "secret-reader";
        };

        sops = {
          age = {
            keyFile = "/var/lib/sops-nix/key.txt";
            sshKeyPaths = lib.mkForce [ ];
          };
          validateSopsFiles = false;
          defaultSopsFile = "/run/enrollment-test/secret.yaml";
          secrets.application-token = {
            owner = "secret-reader";
            group = "secret-reader";
            mode = "0440";
          };
        };

        environment.systemPackages = [
          pkgs.age
          pkgs.sops
        ];

        systemd.services.secret-dependent = {
          wantedBy = [ "multi-user.target" ];
          unitConfig.ConditionPathExists = config.sops.secrets.application-token.path;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
      };
    testScript = ''
      import shlex

      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("comin.service")
      machine.fail("systemctl is-active secret-dependent.service")

      machine.succeed("mkdir -p /run/enrollment-test")
      sentinel = machine.succeed("head -c 24 /dev/urandom | base64 -w0").strip()
      machine.succeed("age-keygen -o /run/enrollment-test/key.txt 2>/run/enrollment-test/recipient")
      recipient = machine.succeed("sed -n 's/^Public key: //p' /run/enrollment-test/recipient").strip()
      machine.succeed(
          "echo application-token: " + shlex.quote(sentinel)
          + " | SOPS_AGE_RECIPIENTS=" + shlex.quote(recipient)
          + " sops --encrypt --input-type yaml --output-type yaml /dev/stdin > /run/enrollment-test/secret.yaml"
      )
      machine.succeed("install -D -m 0600 /run/enrollment-test/key.txt /var/lib/sops-nix/key.txt")
      machine.succeed("/run/current-system/activate")
      machine.succeed("systemctl start secret-dependent.service")
      machine.succeed("test $(stat -c %U:%G /run/secrets/application-token) = secret-reader:secret-reader")
      machine.succeed("test $(stat -c %a /run/secrets/application-token) = 440")
      machine.succeed("test $(cat /run/secrets/application-token) = " + shlex.quote(sentinel))

      machine.fail("nix-store --query --requisites /run/current-system | grep -F " + shlex.quote(sentinel))
      machine.fail("grep -RFl --binary-files=without-match " + shlex.quote(sentinel) + " /etc/systemd/system")
      machine.fail("grep -RFl --binary-files=without-match " + shlex.quote(sentinel) + " /nix/store")

      machine.succeed("cp -a /run/current-system /run/enrollment-test/reachable-generation")
      machine.succeed("age-keygen -o /run/enrollment-test/wrong-key.txt 2>/run/enrollment-test/wrong-recipient")
      wrong_recipient = machine.succeed("sed -n 's/^Public key: //p' /run/enrollment-test/wrong-recipient").strip()
      machine.succeed(
          "echo application-token: " + shlex.quote(sentinel)
          + " | SOPS_AGE_RECIPIENTS=" + shlex.quote(wrong_recipient)
          + " sops --encrypt --input-type yaml --output-type yaml /dev/stdin > /run/enrollment-test/secret.yaml"
      )
      machine.fail("/run/current-system/bin/switch-to-configuration test")
      machine.succeed("test $(readlink -f /run/current-system) = $(readlink -f /run/enrollment-test/reachable-generation)")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("comin.service")
    '';
  };
in
pkgs.runCommand "secrets-check" { } ''
  test -e ${enrollment}
  test -e ${vm}
  touch $out
''
