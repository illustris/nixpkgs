{ lib, substituteAll, bash, coreutils, gnused, firmware ? pkgs.raspberrypifw }:

substituteAll {
  src = ./raspberrypi-builder.sh;
  isExecutable = true;
  inherit bash firmware;
  path = lib.makeBinPath [ coreutils gnused ];
}
