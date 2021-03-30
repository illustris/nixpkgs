{ lib, stdenv, fetchurl, makeWrapper, dpkg, jre_headless, nixosTests }:

let
  pname = "jibri";
  version = "8.0-61-g99288dc";
  src = fetchurl {
    url = "https://download.jitsi.org/stable/${pname}_${version}-1_all.deb";
    sha256 = "0683lnsibdx3bbr03bh53wwc5w4zkjc4z8c4srs3jpzcla33jgjh";
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  dontBuild = true;

  unpackCmd = "${dpkg}/bin/dpkg-deb -x $src debcontents";

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    sed -ir 's~exec java~exec ${jre_headless}/bin/java~g' opt/jitsi/jibri/launch.sh
    sed -ir 's~-Dconfig.file="/etc/jitsi/jibri/jibri.conf"~-Dconfig.file="$JIBRI_CONF"~g' opt/jitsi/jibri/launch.sh
    sed -ir 's~-Djava.util.logging.config.file=/etc/jitsi/jibri/logging.properties~-Djava.util.logging.config.file="$LOGGING_CONFIG"~g' opt/jitsi/jibri/launch.sh
    sed -ir 's~--config "/etc/jitsi/jibri/config.json"~--config "$JIBRI_CONF_JSON"~g' opt/jitsi/jibri/launch.sh
    sed -ir 's~/opt/jitsi/jibri/jibri.jar~$(dirname "$(readlink -f "$0")")/jibri.jar~g' opt/jitsi/jibri/launch.sh
    mkdir -p $out/bin
    mv opt/jitsi/jibri/jibri.jar $out/bin/
    mv opt/jitsi/jibri/launch.sh $out/bin/jibri_launch
    mv etc $out/etc
    mv opt $out/opt
    runHook postInstall
  '';
}