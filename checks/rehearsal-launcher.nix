{ pkgs }:
let
  driver = pkgs.writeShellScriptBin "nixos-test-driver" ''
    touch "$DRIVER_MARKER"
    exit 1
  '';
  launcher = pkgs.callPackage ../packages/hl-node-02-rehearsal.nix { inherit driver; };
  python = pkgs.python3.withPackages (p: [
    p.ptpython
    p.ipython
  ]);
  historyDriver = pkgs.writeShellScriptBin "nixos-test-driver" ''
    ${python}/bin/python - <<'PY'
    import os
    from ptpython.ipython import InteractiveShellEmbed, load_default_config
    from prompt_toolkit.history import FileHistory
    path = os.path.join(os.getcwd(), '.nixos-test-history')
    assert os.path.islink(path) and os.readlink(path) == '/dev/null'
    history = FileHistory(path)
    history.append_string('public synthetic history probe')
    assert list(FileHistory(path).load_history_strings()) == []
    config = load_default_config()
    shell = InteractiveShellEmbed(config=config, history_filename=path)
    assert shell.history_manager.hist_file == ':memory:'
    assert not shell.history_manager.enabled
    shell.run_cell('42', store_history=True)
    shell.history_manager.writeout_cache()
    assert not any(name.endswith('.sqlite') for root, dirs, files in os.walk(os.environ['IPYTHONDIR']) for name in files)
    open(os.environ['DRIVER_MARKER'], 'w').write('history verified')
    open('output/evidence', 'w').write('synthetic evidence retained')
    PY
  '';
  boundaries = pkgs.symlinkJoin {
    name = "rehearsal-hardware-boundaries";
    paths = [
      (pkgs.writeShellScriptBin "findmnt" "echo /dev/synthetic")
      (pkgs.writeShellScriptBin "lsblk" ''
        # Like util-linux, TYPE-only JSON is flat unless tree output is
        # explicitly enabled. Do not give a broken discovery call a tree.
        tree=false
        for argument in "$@"; do
          case "$argument" in
            --tree|--tree=*|-T|NAME|NAME,*|*,NAME|*,NAME,*) tree=true ;;
          esac
        done
        if "$tree"; then
          printf '%s\n' "$ANCESTRY"
        else
          printf '%s\n' "$ANCESTRY" | ${pkgs.jq}/bin/jq '{blockdevices: [.blockdevices[] | recurse(.children[]?) | del(.children)]}'
        fi
      '')
      (pkgs.writeShellScriptBin "unshare" ''
        touch "$NAMESPACE_MARKER"
        test "$NAMESPACE_FAILURE" != 1 || exit 1
        # Namespace networking is independently checked in production; this
        # boundary invokes only a synthetic history driver, never QEMU.
        exec ${historyDriver}/bin/nixos-test-driver
      '')
    ];
  };
  probe = pkgs.callPackage ../packages/hl-node-02-rehearsal.nix {
    driver = historyDriver;
    util-linux = boundaries;
  };
in
pkgs.runCommand "rehearsal-launcher-rejections" { } ''
  export DRIVER_MARKER="$PWD/driver-ran"
  mkdir -m 700 scratch
  ln -s "$PWD/scratch" link
  for directory in "$PWD/missing" scratch "$PWD/link" "$PWD/scratch"; do
    if ${launcher}/bin/hl-node-02-rehearsal "$directory" >rejection.log 2>&1; then
      echo "Accepted unsafe rehearsal directory: $directory" >&2
      exit 1
    fi
    case "$directory" in
      "$PWD/link") expected='scratch must be canonical, without symlinks' ;;
      "$PWD/scratch") expected='scratch must use an identifiable block filesystem' ;;
      *) expected='scratch must be an existing absolute directory' ;;
    esac
    grep -Fx "rehearsal: $expected" rejection.log
    test ! -e "$DRIVER_MARKER"
    test -z "$(ls -A scratch)"
  done
  chmod 755 scratch
  if ${launcher}/bin/hl-node-02-rehearsal "$PWD/scratch" >rejection.log 2>&1; then
    exit 1
  fi
  grep -Fx 'rehearsal: scratch must not grant group or other access' rejection.log
  test ! -e "$DRIVER_MARKER"
  test -z "$(ls -A scratch)"
  # Replace only the inaccessible KVM boundary in the sandbox copy. The real
  # launcher retains its guard; all path/storage/history/cleanup logic executes.
  cp ${probe}/bin/hl-node-02-rehearsal probe
  chmod +w probe
  substituteInPlace probe --replace-fail '[[ -r /dev/kvm && -w /dev/kvm ]]' 'true'
  mkdir -m 700 /build/r
  export NAMESPACE_MARKER="$PWD/namespace-entered"
  export NAMESPACE_FAILURE=1
  for tree in \
    '{"type":"disk"}' \
    '{"type":"raid1","children":[{"type":"crypt","children":[{"type":"disk"}]},{"type":"disk"}]}' \
    '{"type":"crypt","children":[{"type":"disk"},{"type":"disk"}]}' \
    '{"type":"lvm","children":[{"type":"crypt","children":[{"type":"disk"}]}]}'; do
    export ANCESTRY="{\"blockdevices\":[$tree]}"
    if ./probe /build/r >rejection.log 2>&1; then exit 1; fi
    grep -Fx 'rehearsal: scratch must have supported unambiguous encrypted ancestry' rejection.log
    test -z "$(ls -A /build/r)"
  done
  export ANCESTRY='{"blockdevices":[{"type":"crypt","children":[{"type":"part","children":[{"type":"disk"}]}]}]}'
  if ./probe /build/r >namespace.log 2>&1; then exit 1; fi
  if test ! -e "$NAMESPACE_MARKER"; then
    cat namespace.log >&2
    echo 'Supported encrypted ancestry must reach the namespace boundary' >&2
    exit 1
  fi
  test -z "$(ls -A /build/r)"
  test ! -e "$DRIVER_MARKER"
  export NAMESPACE_FAILURE=0
  if ! ./probe /build/r >success.log 2>&1; then
    cat success.log >&2
    echo 'Supported encrypted ancestry must reach the synthetic driver' >&2
    exit 1
  fi
  test "$(cat "$DRIVER_MARKER")" = 'history verified'
  test "$(cat /build/r/.hlr.*/output/evidence)" = 'synthetic evidence retained'
  touch $out
''
