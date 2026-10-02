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

    expect_rejected() {
      name=$1
      key=$2
      if HOST_KEY_PATH="$key" HOST_NAME=test-host ${fleetEnroll}/bin/fleet-enroll >"$name.out" 2>"$name.err"; then
        echo "fleet-enroll accepted invalid key fixture: $name" >&2
        exit 1
      fi
      test ! -s "$name.out"
    }

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
    grep -Fx ".sops.yaml host anchor: &test-host $recipient" enrollment.out
    if grep -F 'PRIVATE KEY' enrollment.out; then
      echo "fleet-enroll printed private key material" >&2
      exit 1
    fi

    cat etc/ssh/ssh_host_ed25519_key.pub etc/ssh/ssh_host_ed25519_key.pub >multiline.pub
    expect_rejected multiline multiline.pub
    ssh-keygen -q -t rsa -b 2048 -N "" -f rsa-key
    expect_rejected rsa rsa-key.pub
    printf '%s\n' 'ssh-ed25519 not-base64 malformed' >malformed-base64.pub
    expect_rejected malformed-base64 malformed-base64.pub
    printf '%s\n' 'not-an-ssh-public-key' >malformed-record.pub
    expect_rejected malformed-record malformed-record.pub
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' >private-marker.pub
    expect_rejected private-marker private-marker.pub
    touch $out
  '';

  policy = pkgs.runCommand "sops-policy-tests" { } ''
    grep -F 'path_regex: secrets/hosts/framework-01/.*\.yaml$' ${../.sops.yaml}
    grep -F 'path_regex: secrets/pi-connectors/.*\.yaml$' ${../.sops.yaml}
    grep -F 'path_regex: secrets/framework-runners/.*\.yaml$' ${../.sops.yaml}
    if grep -F '.*\\.yaml$' ${../.sops.yaml}; then
      echo "sops policy contains a doubled regex backslash" >&2
      exit 1
    fi
    touch $out
  '';

  vm = pkgs.testers.runNixOSTest {
    name = "secrets";
    nodes.client = { pkgs, ... }: {
      environment.systemPackages = [ pkgs.openssh ];
    };
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
        specialisation.candidate.configuration.environment.etc."candidate-generation".text = "distinct";
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

      client.start()
      machine.start()
      client.wait_for_unit("multi-user.target")
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("comin.service")
      machine.fail("systemctl is-active secret-dependent.service")

      client.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /run/test-client-key")
      client_public_key = client.succeed("cat /run/test-client-key.pub").strip()
      machine.succeed("install -d -m 0700 /root/.ssh")
      machine.succeed(
          "printf '%s\\n' " + shlex.quote(client_public_key)
          + " > /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys"
      )
      machine_address = machine.succeed(
          "ip -4 -o address show dev eth1 | awk '{print $4}' | cut -d/ -f1"
      ).strip()
      ssh_command = (
          "ssh -i /run/test-client-key -o BatchMode=yes -o StrictHostKeyChecking=no "
          + "-o UserKnownHostsFile=/dev/null root@" + shlex.quote(machine_address) + " true"
      )
      client.succeed(ssh_command)

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
      machine.fail("grep -aRFl " + shlex.quote(sentinel) + " /etc/systemd/system 2>/dev/null")
      machine.fail("find /nix/store -type f -readable -exec grep -aFl " + shlex.quote(sentinel) + " {} + 2>/dev/null")

      machine.succeed("cp -a /run/current-system /run/enrollment-test/reachable-generation")
      candidate = machine.succeed("readlink -f /run/current-system/specialisation/candidate").strip()
      machine.succeed("test " + shlex.quote(candidate) + " != $(readlink -f /run/current-system)")
      machine.succeed("age-keygen -o /run/enrollment-test/wrong-key.txt 2>/run/enrollment-test/wrong-recipient")
      wrong_recipient = machine.succeed("sed -n 's/^Public key: //p' /run/enrollment-test/wrong-recipient").strip()
      machine.succeed(
          "echo application-token: " + shlex.quote(sentinel)
          + " | SOPS_AGE_RECIPIENTS=" + shlex.quote(wrong_recipient)
          + " sops --encrypt --input-type yaml --output-type yaml /dev/stdin > /run/enrollment-test/secret.yaml"
      )
      machine.fail(shlex.quote(candidate) + "/bin/switch-to-configuration test")
      machine.succeed("test $(readlink -f /run/current-system) = $(readlink -f /run/enrollment-test/reachable-generation)")
      machine.wait_for_unit("sshd.service")
      machine.wait_for_unit("comin.service")
      client.succeed(ssh_command)
    '';
  };
in
pkgs.runCommand "secrets-check" { } ''
  test -e ${enrollment}
  test -e ${policy}
  test -e ${vm}
  touch $out
''
