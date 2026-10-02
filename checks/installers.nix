{ pkgs }:
pkgs.runCommand "installer-safety-tests"
  {
    nativeBuildInputs = [ pkgs.bash ];
  }
  ''
    export PATH=${pkgs.bash}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin
    export BASH=${pkgs.bash}/bin/bash
    export COREUTILS=${pkgs.coreutils}
    export GUARD_TEMPLATE=${../installers/destructive-device-guard.sh}
    export FRAMEWORK_TEMPLATE=${../installers/framework-install.sh}
    bash ${./installer-safety-tests.sh}
    touch "$out"
  ''
