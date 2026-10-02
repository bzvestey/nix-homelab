{ pkgs }:
pkgs.runCommand "installer-safety-tests"
  {
    nativeBuildInputs = [ pkgs.bash ];
  }
  ''
    export PATH=${pkgs.bash}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin
    export GUARD=${../installers/destructive-device-guard.sh}
    bash ${./installer-safety-tests.sh}
    touch "$out"
  ''
