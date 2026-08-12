{ lib, pkgs, ... }:

let
  # Served as the OpenStack "uuid" metadata key (which cloud-init copies to
  # instance-id) and advertised over SMBIOS as the system uuid.
  instanceUuid = "5a3b0e8c-8b7f-4b2e-9c1a-6f2d3e4a5b60";
  expectedHostname = "cloudinit-dhcp-test";

  # Newest version in cloudinit.sources.helpers.openstack.OS_VERSIONS, so
  # _find_working_version() settles on it deterministically.
  osVersion = "2018-08-27";

  imdsAddress = "169.254.169.254";

  metadataRoot =
    pkgs.runCommand "openstack-metadata"
      {
        # "uuid" is the only key read_v2() insists on; "hostname" becomes
        # local-hostname.
        metaData = builtins.toJSON {
          uuid = instanceUuid;
          hostname = expectedHostname;
          name = expectedHostname;
        };
        userData = ''
          #cloud-config
          write_files:
            - path: /tmp/cloudinit-dhcp-user-data
              content: |
                ephemeral-dhcp-ok
        '';
        versions = ''
          ${osVersion}
          latest
        '';
        passAsFile = [
          "metaData"
          "userData"
          "versions"
        ];
      }
      ''
        mkdir -p $out/openstack/${osVersion}
        cp $metaDataPath $out/openstack/${osVersion}/meta_data.json
        cp $userDataPath $out/openstack/${osVersion}/user_data
        cp $versionsPath $out/versions
        ln -s ${osVersion} $out/openstack/latest
      '';
in
{
  name = "cloud-init-dhcp";
  meta.maintainers = [ lib.maintainers.illustris ];

  nodes = {
    # Mock OpenStack metadata service, reachable only over the ephemeral DHCP
    # lease that cloud-init has to obtain for itself.
    imds =
      { ... }:
      {
        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = imdsAddress;
            prefixLength = 16;
          }
        ];

        # Leases come out of 169.254.0.0/16 so that imdsAddress is on-link for
        # the client without any extra routes, mirroring real link-local IMDS.
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            port = 0;
            interface = "eth1";
            bind-dynamic = true;
            dhcp-authoritative = true;
            dhcp-range = [ "169.254.1.10,169.254.1.100,255.255.0.0,12h" ];
            # Hand out neither a router nor a nameserver: the client only ever
            # needs to reach the on-link metadata address.
            dhcp-option = [
              "3"
              "6"
            ];
          };
        };

        services.nginx = {
          enable = true;
          virtualHosts.imds = {
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
            ];
            root = metadataRoot;
            # /openstack is a plain newline separated version listing, so it
            # cannot also be the directory holding the versions.
            locations."= /openstack".extraConfig = ''
              default_type text/plain;
              alias ${metadataRoot}/versions;
            '';
            # read_v2() always probes the EC2 compatible tree as well. An
            # empty listing is a valid answer and keeps the crawl from
            # retrying a 404.
            locations."= /latest/meta-data/".extraConfig = ''
              default_type text/plain;
              return 200 "";
            '';
          };
        };

        networking.firewall = {
          allowedUDPPorts = [ 67 ];
          allowedTCPPorts = [ 80 ];
        };
      };

    target =
      { ... }:
      {
        # DataSourceOpenStack.ds_detect() gates on the DMI product name even
        # when datasource_list is pinned.
        virtualisation.qemu.options = [
          ''-smbios "type=1,product=OpenStack Nova,uuid=${instanceUuid}"''
        ];

        # cloud-init runs its ephemeral DHCP on distro.fallback_interface,
        # which prefers eth0. eth0 is qemu's user-mode NIC and answers DHCP
        # from its own built-in server, so drop it and leave the vlan NIC as
        # the only candidate. The test driver talks over the serial backdoor,
        # not the network, so nothing else needs it.
        virtualisation.qemu.networkingOptions = lib.mkForce [ ];

        services.cloud-init = {
          enable = true;
          network.enable = true;
          settings = {
            datasource_list = [ "OpenStack" ];
            datasource.OpenStack = {
              metadata_urls = [ "http://${imdsAddress}" ];
              max_wait = 120;
              timeout = 5;
              retries = 1;
            };
          };
        };

        networking.hostName = "";
        # No OS level DHCP client may compete; the lease has to come from
        # cloud-init invoking dhcpcd itself.
        networking.useDHCP = false;
      };
  };

  testScript = ''
    import json
    import re

    # Bring the metadata service up first so the client's very first DHCP
    # discovery already has something to answer it.
    imds.start()
    imds.wait_for_unit("dnsmasq.service")
    imds.wait_for_unit("nginx.service")
    imds.wait_for_open_port(80)

    target.start()
    target.wait_for_unit("multi-user.target")

    # The cloud.cfg the NixOS module generates carries no log_cfgs, so
    # /var/log/cloud-init.log stays empty and the journal is the only place
    # the debug log lands.
    local_log = target.succeed("journalctl -o cat -u cloud-init-local.service")
    print(local_log)

    target.wait_for_unit("cloud-init-local.service")
    target.wait_for_unit("cloud-final.service")

    # dhcpcd, and only dhcpcd, performed the ephemeral DHCP on the vlan NIC.
    assert "DHCP client selected: dhcpcd" in local_log
    assert "Performing a dhcp discovery on eth1" in local_log
    assert "udhcpc" not in local_log
    assert re.search(
        r"Running command \['dhcpcd', '--ipv4only', '--waitip'.*'eth1'\]", local_log
    ), "dhcpcd was not the client that ran the discovery"

    assert re.search(
        r"Received dhcp lease on eth1 for 169\.254\.1\.\d+/255\.255\.0\.0", local_log
    ), "no dhcpcd lease from the mock DHCP server on eth1"

    # The metadata really came back over that ephemeral link.
    assert "http://${imdsAddress}/openstack/${osVersion}/meta_data.json" in local_log

    instance_data = json.loads(target.succeed("cat /run/cloud-init/instance-data.json"))
    assert instance_data["v1"]["platform"] == "openstack"
    assert instance_data["v1"]["instance_id"] == "${instanceUuid}"
    assert instance_data["v1"]["local_hostname"] == "${expectedHostname}"

    # The local (pre-networking) variant is the one that does its own DHCP.
    assert "DataSourceOpenStackLocal" in target.succeed(
        "cat /var/lib/cloud/instance/datasource"
    )
    assert target.succeed("hostname").strip() == "${expectedHostname}"
    assert "ephemeral-dhcp-ok" in target.succeed("cat /tmp/cloudinit-dhcp-user-data")
  '';
}
