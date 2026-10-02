{
  hostname,
  ssh-to-age,
  writeShellApplication,
}:
writeShellApplication {
  name = "fleet-enroll";
  runtimeInputs = [
    hostname
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

    public_key=$(cat "$public_key_path")
    recipient=$(printf '%s\n' "$public_key" | ssh-to-age)
    printf 'SSH public key: %s\n' "$public_key"
    printf 'age recipient: %s\n' "$recipient"
    printf '.sops.yaml host anchor: &%s %s\n' "$host_name" "$recipient"
  '';
}
