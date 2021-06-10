{ lib, substituteAll, bash, coreutils, gnused }:

substituteAll {
  src = ./raspberrypi-builder.sh;
  isExecutable = true;
  inherit bash firmware;
  path = lib.makeBinPath [ coreutils gnused ];
}
