{
  lib,
  nixosTests,
  bash-completion,
  bashNonInteractive,
  cloud-utils,
  dmidecode,
  fetchFromGitHub,
  iproute2,
  meson,
  ninja,
  openssh,
  pkg-config,
  python3,
  shadow,
  systemd,
  coreutils,
  dhcpcd,
  gitUpdater,
  procps,
}:

python3.pkgs.buildPythonApplication (finalAttrs: {
  pname = "cloud-init";
  version = "26.2";
  # cloud-init switched from setuptools to meson (PEP 632), so we drive
  # the meson build/install ourselves.
  format = "other";

  namePrefix = "";

  src = fetchFromGitHub {
    owner = "canonical";
    repo = "cloud-init";
    tag = finalAttrs.version;
    hash = "sha256-OFgn1zOoWivNB5JPszFjhSzmILDRJ9aR9A9y81oBwMk=";
  };

  patches = [
    ./0001-add-nixos-support.patch
    ./0002-fix-test-logs-on-nixos.patch
  ];

  prePatch = ''
    substituteInPlace tools/render-template \
      --replace-fail "#!/usr/bin/env python3" "#!${python3.interpreter}"

    substituteInPlace cloudinit/net/networkd.py \
      --replace-fail '["/usr/sbin", "/bin"]' '["/usr/sbin", "/bin", "${iproute2}/bin", "${systemd}/bin"]'

    substituteInPlace tests/unittests/test_net_activators.py \
      --replace-fail '["/usr/sbin", "/bin"]' \
        '["/usr/sbin", "/bin", "${iproute2}/bin", "${systemd}/bin"]'

    # cc_install_hotplug writes a udev rule invoking /usr/libexec/cloud-init/hook-hotplug,
    # which does not exist on NixOS; the test asserts the same literal path
    substituteInPlace cloudinit/config/cc_install_hotplug.py tests/unittests/config/test_cc_install_hotplug.py \
      --replace-fail "/usr/libexec/cloud-init" "$out/libexec/cloud-init"

    # dhcpcd's hooks are disabled by pointing --script at /bin/true, which does
    # not exist on NixOS; the tests assert the same literal command line
    substituteInPlace cloudinit/net/dhcp.py tests/unittests/net/test_dhcp.py \
      --replace-fail '"--script=/bin/true"' '"--script=${coreutils}/bin/true"'
  '';

  nativeBuildInputs = [
    meson
    ninja
    # resolves the systemd, udev and bash-completion install dirs below
    pkg-config
  ];

  buildInputs = [
    # provides a store-path sh for patchShebangs of the installed scripts
    # (strictDeps: shebang interpreters are only looked up in buildInputs)
    bashNonInteractive
    # .pc files consulted by meson for install dirs; the dirs themselves are
    # redirected into $out via the PKG_CONFIG_* overrides in env
    bash-completion
    systemd
  ];

  mesonFlags = [
    # python.install_env=prefix installs modules into
    # $out/lib/python3.x/site-packages (the default "auto" scheme would use
    # the build python's own prefix instead)
    "-Dpython.install_env=prefix"
    # the default prefix-relative "etc" works for regular install rules, but
    # upstream's clean.d install script mkdirs ${DESTDIR}/$sysconfdir verbatim;
    # an absolute path keeps it inside $out
    "--sysconfdir=${placeholder "out"}/etc"
  ];

  env = {
    # upstream reads these install dirs from systemd.pc/udev.pc/bash-completion.pc,
    # which point at those packages' own prefixes
    PKG_CONFIG_SYSTEMD_SYSTEMDSYSTEMUNITDIR = "${placeholder "out"}/lib/systemd/system";
    PKG_CONFIG_SYSTEMD_SYSTEMDSYSTEMGENERATORDIR = "${placeholder "out"}/lib/systemd/system-generators";
    PKG_CONFIG_UDEV_UDEVDIR = "${placeholder "out"}/lib/udev";
    PKG_CONFIG_BASH_COMPLETION_COMPLETIONSDIR = "${placeholder "out"}/share/bash-completion/completions";
  };

  postInstall = ''
    for i in $out/libexec/cloud-init/*; do
      wrapProgram $i --prefix PATH : "${lib.makeBinPath [ openssh ]}"
    done

    # tools/render-template autodetects the build machine's distro variant,
    # which resolves to the ubuntu fallback inside the sandbox; the nixos
    # distro class comes from 0001-add-nixos-support.patch
    substituteInPlace $out/etc/cloud/cloud.cfg \
      --replace-fail "distro: ubuntu" "distro: nixos"
  '';

  propagatedBuildInputs = with python3.pkgs; [
    configobj
    jinja2
    jsonpatch
    jsonschema
    oauthlib
    pyserial
    pyyaml
    requests
  ];

  nativeCheckInputs = with python3.pkgs; [
    pytest7CheckHook
    pyfakefs
    dmidecode
    # needed for tests; at runtime we rather want the setuid wrapper
    passlib
    shadow
    responses
    pytest-mock
    coreutils
    procps
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${
      lib.makeBinPath [
        dmidecode
        cloud-utils.guest
        dhcpcd
      ]
    }"
  ];

  disabledTests = [
    # tries to create /var
    "test_dhcp_client_failover"
    # clears path and fails because mkdir is not found
    "test_path_env_gets_set_from_main"
    # tries to read from /etc/ca-certificates.conf while inside the sandbox
    "TestRemoveDefaultCaCerts"
    # Doesn't work in the sandbox
    "TestEphemeralDhcpNoNetworkSetup"
    "TestReadFileOrUrl"
    "TestConsumeUserDataHttp"
    # Chef Omnibus
    "TestInstallChefOmnibus"
    # Disable failing VMware and PuppetAio tests
    "test_get_data_vmware_guestinfo_with_network_config"
    "test_no_data_access_method"
    # needs to chmod the setuid bit, not permitted as sandbox user
    "test_special_permission_bits"
    # https://github.com/canonical/cloud-init/issues/5002
    "test_found_via_userdata"
  ];

  preCheck = ''
    # pytestCheckPhase runs with cwd inside the meson build dir; go back to
    # the source root so pytest resolves tox.ini testpaths (tools tests/unittests)
    cd ..
    # TestTempUtils.test_mkdtemp_default_non_root does not like TMPDIR=/build
    export TMPDIR=/tmp
  '';

  pythonImportsCheck = [
    "cloudinit"
  ];

  passthru = {
    tests = {
      inherit (nixosTests)
        cloud-init
        cloud-init-dhcp
        cloud-init-hostname
        ;
    };
    updateScript = gitUpdater { ignoredVersions = ".ubuntu.*"; };
  };

  meta = {
    homepage = "https://github.com/canonical/cloud-init";
    description = "Provides configuration and customization of cloud instance";
    changelog = "https://github.com/canonical/cloud-init/raw/${finalAttrs.version}/ChangeLog";
    license = with lib.licenses; [
      asl20
      gpl3Plus
    ];
    maintainers = with lib.maintainers; [
      illustris
      jfroche
    ];
    platforms = lib.platforms.all;
  };
})
