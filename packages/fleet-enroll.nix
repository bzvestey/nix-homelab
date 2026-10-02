{
  hostname,
  openssh,
  ssh-to-age,
  writeShellApplication,
}:
writeShellApplication {
  name = "fleet-enroll";
  runtimeInputs = [
    hostname
    openssh
    ssh-to-age
  ];
  text = ''
    public_key_path="''${HOST_KEY_PATH:-/etc/ssh/ssh_host_ed25519_key.pub}"
    host_name="''${HOST_NAME:-$(hostname)}"

    if [ ! -r "$public_key_path" ]; then
      echo "fleet-enroll: missing SSH host public key: $public_key_path" >&2
      exit 1
    fi
    case "$host_name" in
      ""|*[!a-zA-Z0-9-]*)
        echo "fleet-enroll: invalid host name: $host_name" >&2
        exit 1
        ;;
    esac

    if grep -q 'PRIVATE KEY' "$public_key_path"; then
      echo "fleet-enroll: invalid Ed25519 SSH host public key" >&2
      exit 1
    fi
    if [ "$(awk 'END { print NR }' "$public_key_path")" -ne 1 ]; then
      echo "fleet-enroll: SSH host public key must contain exactly one record" >&2
      exit 1
    fi

    public_key=$(cat "$public_key_path")
    case "$public_key" in
      *$'\r'*)
        echo "fleet-enroll: invalid Ed25519 SSH host public key" >&2
        exit 1
        ;;
    esac
    key_type=
    key_data=
    _key_comment=
    IFS=' ' read -r key_type key_data _key_comment <<< "$public_key"
    if [ "$key_type" != ssh-ed25519 ] || [ -z "$key_data" ] \
      || ! ssh-keygen -l -f "$public_key_path" >/dev/null 2>&1; then
      echo "fleet-enroll: invalid Ed25519 SSH host public key" >&2
      exit 1
    fi

    recipient=$(printf '%s\n' "$public_key" | ssh-to-age)
    printf 'SSH public key: %s\n' "$public_key"
    printf 'age recipient: %s\n' "$recipient"
    printf '.sops.yaml host anchor: &%s %s\n' "$host_name" "$recipient"
  '';
}
