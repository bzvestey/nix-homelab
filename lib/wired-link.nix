{
  matchConfig = {
    Type = "ether";
    Path = "*";
  };

  selectScript = ''
    set -eu
    sys_class_net="''${SYS_CLASS_NET:-/sys/class/net}"
    for link in "$sys_class_net"/*; do
      [ -e "$link/type" ] || continue
      [ "$(cat "$link/type")" = 1 ] || continue
      [ -e "$link/device" ] || continue
      [ ! -e "$link/wireless" ] || continue
      basename "$link"
    done
  '';
}
