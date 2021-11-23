{ lib
, buildPythonPackage
, fetchPypi
, jupyterhub
, tornado
, bash
, skein
, hadoop
}:

buildPythonPackage rec {
  pname = "jupyterhub-yarnspawner";
  version = "0.4.0";

  src = fetchPypi {
    inherit pname version;
    sha256 = "0sw27h145zk8yr37k8gbib4pwvbxxf7n4b0157cq26d3h46170iv";
  };

  propagatedBuildInputs = [
    jupyterhub
    tornado
    skein
    hadoop
  ];

  #postPatch = ''
  #  substituteInPlace systemdspawner/systemd.py \
  #    --replace "/bin/bash" "${bash}/bin/bash"

  #  substituteInPlace systemdspawner/systemdspawner.py \
  #    --replace "/bin/bash" "${bash}/bin/bash"
  #'';

  # no tests
  doCheck = false;

  #meta = with lib; {
    #description = "JupyterHub Spawner using systemd for resource isolation";
    #homepage = "https://github.com/jupyterhub/systemdspawner";
    #license = licenses.bsd3;
    #maintainers = [ maintainers.costrouc ];
  #};
}
