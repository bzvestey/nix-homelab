{
  lib,
  python3,
  runCommand,
  makeWrapper,
  sops,
}:
let
  python = python3.withPackages (ps: [
    ps.python-socketio
    ps.requests
    ps.websocket-client
  ]);
in
runCommand "kuma-reconciler-2.5.6"
  {
    passthru = { inherit python; };
    nativeBuildInputs = [ makeWrapper ];
  }
  ''
    mkdir -p $out/lib/kuma-reconciler
    cp ${./client.py} $out/lib/kuma-reconciler/client.py
    cp ${./reconcile.py} $out/lib/kuma-reconciler/reconcile.py
    cp ${./provision.py} $out/lib/kuma-reconciler/provision.py
    mkdir -p $out/bin
    makeWrapper ${python}/bin/python $out/bin/kuma-reconciler \
      --add-flags "$out/lib/kuma-reconciler/reconcile.py" \
      --set PYTHONDONTWRITEBYTECODE 1
    makeWrapper ${python}/bin/python $out/bin/kuma-provision-credential \
      --add-flags "$out/lib/kuma-reconciler/provision.py" \
      --prefix PATH : ${lib.makeBinPath [ sops ]} \
      --set PYTHONDONTWRITEBYTECODE 1
    mkdir -p $out/nix-support
    echo ${python}/bin/python > $out/nix-support/python
  ''
