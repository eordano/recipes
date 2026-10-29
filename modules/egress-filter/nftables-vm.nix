# The routed topology and python checks shared by test-nftables-resolve.nix
# and test-nftables-dnsmasq.nix. The vm sits on its own subnet and reaches the
# servers only through the hypervisor, so its traffic transits the forward
# hook; every interface uses assignIP = false so no node gets a second,
# auto-assigned address. Those are the two ways such a test goes green without
# the filter doing anything (same-subnet bypass, ARP address collision), and
# py's assert_topology guards both.
{
  pkgs,
  withStatic ? false,
}:
let
  inherit (pkgs) lib;
in
rec {
  allowedDomain = "allowed.test";
  blockedDomain = "blocked.test";
  staticAllowedDomain = "static.test";

  guestNet = "192.168.1";
  hypervisorIp = "${guestNet}.1";
  vmIp = "${guestNet}.2";

  serverNet = "192.168.2";
  hypervisorServerIp = "${serverNet}.1";
  allowedIp = "${serverNet}.10";
  blockedIp = "${serverNet}.20";
  staticIp = "${serverNet}.30";

  extraHosts = ''
    ${allowedIp} ${allowedDomain}
    ${blockedIp} ${blockedDomain}
  ''
  + lib.optionalString withStatic ''
    ${staticIp} ${staticAllowedDomain}
  '';

  addr = address: [
    {
      inherit address;
      prefixLength = 24;
    }
  ];
  vlan = n: {
    vlan = n;
    assignIP = false;
  };

  server =
    {
      ip,
      domain,
      name,
    }:
    { pkgs, ... }:
    {
      virtualisation.interfaces.eth1 = vlan 2;
      networking = {
        enableIPv6 = false;
        nftables.enable = false;
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = addr ip;
        defaultGateway = {
          address = hypervisorServerIp;
          interface = "eth1";
        };
        firewall = {
          enable = true;
          allowedTCPPorts = [ 80 ];
          allowPing = true;
        };
        inherit extraHosts;
      };
      services.nginx = {
        enable = true;
        virtualHosts.${domain} = {
          default = true;
          locations."/".root = pkgs.writeTextDir "index.html" ''
            <!DOCTYPE html>
            <html>
            <head><title>${name} Server</title></head>
            <body>
              <h1>Response from ${name}</h1>
              <p>MARKER: ${name}_SUCCESS</p>
            </body>
            </html>
          '';
        };
      };
    };

  servers = {
    allowed = server {
      ip = allowedIp;
      domain = allowedDomain;
      name = "ALLOWED";
    };
    blocked = server {
      ip = blockedIp;
      domain = blockedDomain;
      name = "BLOCKED";
    };
  }
  // lib.optionalAttrs withStatic {
    static = server {
      ip = staticIp;
      domain = staticAllowedDomain;
      name = "STATIC";
    };
  };

  hypervisor =
    { pkgs, ... }:
    {
      virtualisation.interfaces.eth1 = vlan 1;
      virtualisation.interfaces.eth2 = vlan 2;
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      networking = {
        enableIPv6 = false;
        useDHCP = false;
        nftables.enable = true;
        firewall.backend = "nftables";
        interfaces.eth1.ipv4.addresses = addr hypervisorIp;
        interfaces.eth2.ipv4.addresses = addr hypervisorServerIp;
        firewall = {
          enable = true;
          allowPing = true;
        };
        inherit extraHosts;
      };
      environment.systemPackages = with pkgs; [
        curl
        nftables
        dnsutils
        conntrack-tools
      ];
    };

  vm =
    { pkgs, ... }:
    {
      virtualisation.interfaces.eth1 = vlan 1;
      networking = {
        enableIPv6 = false;
        nftables.enable = false;
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = addr vmIp;
        defaultGateway = {
          address = hypervisorIp;
          interface = "eth1";
        };
        firewall.enable = false;
        inherit extraHosts;
      };
      environment.systemPackages = with pkgs; [
        curl
        dnsutils
      ];
    };

  py = ''
    import re
    import sys

    SET = "inet egress-filter egress_allow_eth1"
    FWD_CHAIN = "inet egress-filter egress_fwd_eth1"

    def test_curl(machine, url, expected_marker=None, should_succeed=True, timeout=10):
        cmd = f"curl -s --connect-timeout {timeout} --max-time {timeout} {url} 2>&1"
        (status, output) = machine.execute(cmd)

        if should_succeed:
            if status != 0 or (expected_marker and expected_marker not in output):
                print(f"FAIL: curl to {url}")
                print(f"Status: {status}, Output: {output}")
                return False
            print(f"OK: Successfully accessed {url}")
            return True
        else:
            if status == 0 and expected_marker and expected_marker in output:
                print(f"FAIL: Should not have accessed {url}")
                return False
            print(f"OK: Access to {url} blocked as expected")
            return True

    def assert_topology(nodes, servers):
        for (machine, iface, want) in [
            (hypervisor, "eth1", "${hypervisorIp}"),
            (hypervisor, "eth2", "${hypervisorServerIp}"),
            (vm, "eth1", "${vmIp}"),
        ] + [(n, "eth1", ip) for (n, ip) in nodes]:
            addrs = machine.succeed(
                f"ip -4 -o addr show dev {iface} | awk '{{print $4}}'"
            ).split()
            assert addrs == [f"{want}/24"], \
                f"{iface} should hold exactly [{want}/24], holds {addrs}"
        print("  OK: no auto-assigned extra addresses (no ARP ambiguity)")

        for dest in servers:
            route = vm.succeed(f"ip route get {dest}").strip()
            assert "via ${hypervisorIp}" in route, \
                f"vm must reach {dest} via the gateway, got: {route}"
        print("  OK: vm reaches every server only via the hypervisor")

    def unfilter(ip):
        """Put `ip` into the live allow-set, so the forward chain accepts it."""
        hypervisor.succeed(f"nft add element {SET} '{{ {ip} }}'")
        hypervisor.succeed("conntrack -F 2>/dev/null || true")

    def assert_blocked_by_the_filter(refilter):
        # Negative control for the "blocked" assertions: an unreachable server,
        # a missing route or a wrong address would fail the same way. Putting
        # the blocked address into the live allow-set is the smallest change
        # that removes the filter's reason to drop, so it must make the SAME
        # requests succeed; refilter() taking it out again must restore the
        # block, so the success cannot be a warmed ARP/conntrack latch.
        unfilter("${blockedIp}")
        if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=True):
            print("FAIL: with ${blockedIp} in the allow-set the SAME request still")
            print("      failed -- the earlier 'blocked' results were topology, not")
            print("      the egress filter.")
            sys.exit(1)
        if not test_curl(vm, "http://${blockedIp}/", "BLOCKED_SUCCESS", should_succeed=True):
            print("FAIL: direct-IP request still failed with ${blockedIp} allowed.")
            sys.exit(1)
        print("  OK: allow-listing the blocked server makes both requests succeed")

        refilter()
        if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=False):
            sys.exit(1)
        if not test_curl(vm, "http://${blockedIp}/", "BLOCKED_SUCCESS", should_succeed=False):
            sys.exit(1)
        print("  OK: removing it again restores the block -- the allow-set is the")
        print("      discriminator, and the traffic really does transit the filter")

    def assert_forward_chain_counts():
        # A counter at the head of the per-interface forward chain must tick
        # when the vm talks to a server; a vm bypassing the gateway leaves it 0.
        hypervisor.succeed(f"nft insert rule {FWD_CHAIN} counter")
        vm.execute("curl -s --connect-timeout 5 --max-time 5 http://${blockedIp}/ 2>&1")
        vm.execute("curl -s --connect-timeout 5 --max-time 5 http://${allowedDomain}/ 2>&1")
        chain_out = hypervisor.succeed(f"nft list chain {FWD_CHAIN}")
        print(chain_out)
        counted = [int(m) for m in re.findall(r"counter packets (\d+)", chain_out)]
        assert counted and counted[0] > 0, \
            f"forward chain saw no packets -- vm traffic is bypassing it: {chain_out}"
        print(f"  OK: forward chain counted {counted[0]} packets from the vm")
  '';
}
