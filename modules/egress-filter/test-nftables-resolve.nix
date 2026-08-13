{ pkgs, ... }:

let
  egressFilterModule = import ./default.nix;

  allowedDomain = "allowed.test";
  blockedDomain = "blocked.test";

  guestNet = "192.168.1";
  hypervisorIp = "${guestNet}.1";
  vmIp = "${guestNet}.2";

  serverNet = "192.168.2";
  hypervisorServerIp = "${serverNet}.1";
  allowedIp = "${serverNet}.10";
  blockedIp = "${serverNet}.20";

  mkTestPage =
    name:
    pkgs.writeTextFile {
      name = "index.html";
      text = ''
        <!DOCTYPE html>
        <html>
        <head><title>${name} Server</title></head>
        <body>
          <h1>Response from ${name}</h1>
          <p>MARKER: ${name}_SUCCESS</p>
        </body>
        </html>
      '';
      destination = "/index.html";
    };

  mkTestServer =
    {
      ip,
      domain,
      name,
    }:
    { pkgs, ... }:
    {
      virtualisation.interfaces.eth1 = {
        vlan = 2;
        assignIP = false;
      };

      networking = {
        enableIPv6 = false;
        nftables.enable = false;
        useDHCP = false;

        interfaces.eth1.ipv4.addresses = [
          {
            address = ip;
            prefixLength = 24;
          }
        ];

        defaultGateway = {
          address = hypervisorServerIp;
          interface = "eth1";
        };

        firewall = {
          enable = true;
          allowedTCPPorts = [ 80 ];
          allowPing = true;
        };

        extraHosts = ''
          ${allowedIp} ${allowedDomain}
          ${blockedIp} ${blockedDomain}
        '';
      };

      services.nginx = {
        enable = true;
        virtualHosts.${domain} = {
          default = true;
          locations."/" = {
            root = pkgs.runCommand "www-${name}" { } ''
              mkdir -p $out
              cp ${mkTestPage name}/* $out/
            '';
          };
        };
      };
    };

in
pkgs.testers.nixosTest {
  name = "egress-filter-nftables-resolve-test";

  nodes = {
    hypervisor =
      { pkgs, lib, ... }:
      {
        imports = [ egressFilterModule ];

        virtualisation.interfaces.eth1 = {
          vlan = 1;
          assignIP = false;
        };
        virtualisation.interfaces.eth2 = {
          vlan = 2;
          assignIP = false;
        };

        boot.kernel.sysctl = {
          "net.ipv4.ip_forward" = 1;
        };

        networking.enableIPv6 = false;
        networking.useDHCP = false;

        networking.nftables.enable = true;
        networking.firewall.backend = "nftables";

        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = hypervisorIp;
            prefixLength = 24;
          }
        ];
        networking.interfaces.eth2.ipv4.addresses = [
          {
            address = hypervisorServerIp;
            prefixLength = 24;
          }
        ];

        networking.firewall = {
          enable = true;
          allowPing = true;
        };

        networking.extraHosts = ''
          ${allowedIp} ${allowedDomain}
          ${blockedIp} ${blockedDomain}
        '';

        services.egressFilter = {
          enable = true;
          updateInterval = "1m";

          interfaces.eth1 = {
            enable = true;
            mode = "resolve";

            domains = [
              allowedDomain
            ];

            allowPrivateNetworks = false;
            allowDNS = true;

            dnsServers = [ "127.0.0.1" ];
          };
        };

        services.dnsmasq = {
          enable = true;
          settings = {
            interface = "lo";
            bind-interfaces = true;
            no-hosts = false;
            listen-address = "127.0.0.1";
          };
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
        virtualisation.interfaces.eth1 = {
          vlan = 1;
          assignIP = false;
        };

        networking = {
          enableIPv6 = false;
          nftables.enable = false;
          useDHCP = false;

          interfaces.eth1.ipv4.addresses = [
            {
              address = vmIp;
              prefixLength = 24;
            }
          ];

          defaultGateway = {
            address = hypervisorIp;
            interface = "eth1";
          };

          firewall.enable = false;

          extraHosts = ''
            ${allowedIp} ${allowedDomain}
            ${blockedIp} ${blockedDomain}
          '';
        };

        environment.systemPackages = with pkgs; [
          curl
          dnsutils
        ];
      };

    allowed = mkTestServer {
      ip = allowedIp;
      domain = allowedDomain;
      name = "ALLOWED";
    };

    blocked = mkTestServer {
      ip = blockedIp;
      domain = blockedDomain;
      name = "BLOCKED";
    };
  };

  testScript = ''
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

    def unfilter(ip):
        """Put `ip` into the live allow-set, so the forward chain accepts it."""
        hypervisor.succeed(f"nft add element {SET} '{{ {ip} }}'")
        hypervisor.succeed("conntrack -F 2>/dev/null || true")

    def refilter():
        """Rebuild the allow-set from DNS only, via the module's own path."""
        hypervisor.succeed("systemctl start egress-filter-resolve-eth1.service")
        hypervisor.succeed("conntrack -F 2>/dev/null || true")
        out = hypervisor.succeed(f"nft list set {SET}")
        assert "${blockedIp}" not in out, f"allow-set still holds ${blockedIp}:\n{out}"

    print("=" * 60)
    print("EGRESS FILTER TEST - NFTABLES BACKEND, RESOLVE MODE")
    print("=" * 60)

    start_all()

    print("\n[1/8] Waiting for nodes to be ready...")
    hypervisor.wait_for_unit("multi-user.target", timeout=60)
    vm.wait_for_unit("multi-user.target", timeout=60)
    allowed.wait_for_unit("multi-user.target", timeout=60)
    blocked.wait_for_unit("multi-user.target", timeout=60)

    hypervisor.wait_for_unit("nftables.service", timeout=30)
    hypervisor.wait_for_unit("egress-filter-nftables.service", timeout=30)
    hypervisor.wait_for_unit("dnsmasq.service", timeout=30)
    allowed.wait_for_unit("nginx.service", timeout=30)
    blocked.wait_for_unit("nginx.service", timeout=30)

    hypervisor.wait_until_succeeds("ip addr show eth1 | grep '${hypervisorIp}'", timeout=15)
    hypervisor.wait_until_succeeds("ip addr show eth2 | grep '${hypervisorServerIp}'", timeout=15)
    vm.wait_until_succeeds("ip addr show eth1 | grep '${vmIp}'", timeout=15)
    allowed.wait_until_succeeds("ip addr show eth1 | grep '${allowedIp}'", timeout=15)
    blocked.wait_until_succeeds("ip addr show eth1 | grep '${blockedIp}'", timeout=15)
    print("All nodes ready")

    print("\n[2/8] Asserting the topology actually puts the filter in the path...")
    # Guards bug 1 (address collision): with assignIP = false every node must
    # hold EXACTLY the one address this test gave it. An extra auto-assigned
    # address is how two machines end up answering ARP for the same IP.
    for (machine, iface, want) in [
        (hypervisor, "eth1", "${hypervisorIp}"),
        (hypervisor, "eth2", "${hypervisorServerIp}"),
        (vm, "eth1", "${vmIp}"),
        (allowed, "eth1", "${allowedIp}"),
        (blocked, "eth1", "${blockedIp}"),
    ]:
        addrs = machine.succeed(
            f"ip -4 -o addr show dev {iface} | awk '{{print $4}}'"
        ).split()
        assert addrs == [f"{want}/24"], \
            f"{iface} should hold exactly [{want}/24], holds {addrs}"
    print("  OK: no auto-assigned extra addresses (no ARP ambiguity)")

    # Guards bug 2 (same-subnet bypass): the vm must have NO directly
    # connected route to either server, only a route via the hypervisor.
    for dest in ["${allowedIp}", "${blockedIp}"]:
        route = vm.succeed(f"ip route get {dest}").strip()
        assert "via ${hypervisorIp}" in route, \
            f"vm must reach {dest} via the gateway, got: {route}"
    print("  OK: vm reaches both servers only via the hypervisor")

    print("\n[3/8] Testing basic connectivity...")
    allowed.wait_until_succeeds("ping -c 1 ${hypervisorServerIp}", timeout=15)
    blocked.wait_until_succeeds("ping -c 1 ${hypervisorServerIp}", timeout=15)
    vm.wait_until_succeeds("ping -c 1 ${hypervisorIp}", timeout=15)
    print("Basic connectivity OK")

    print("\n[4/8] Running DNS resolution service...")
    hypervisor.succeed("systemctl start egress-filter-resolve-eth1.service")
    hypervisor.sleep(2)
    print("Resolution service completed")

    print("\n[5/8] Checking nftables set state...")
    set_out = hypervisor.succeed(f"nft list set {SET}")
    print("set contents:")
    print(set_out)

    assert "${allowedIp}" in set_out, "Allowed IP not in nftables set!"
    print("  OK: ${allowedIp} is in the allow-set")

    assert "${blockedIp}" not in set_out, "Blocked IP should not be in nftables set!"
    print("  OK: ${blockedIp} is NOT in the allow-set")

    print("\n[6/8] Testing HTTP access from VM...")

    print("  Testing allowed domain...")
    if not test_curl(vm, "http://${allowedDomain}/", "ALLOWED_SUCCESS", should_succeed=True):
        sys.exit(1)

    print("  Testing blocked domain (should fail)...")
    if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)

    print("  Testing direct IP to blocked (should fail)...")
    if not test_curl(vm, "http://${blockedIp}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)

    print("\n[6.5/8] ...and those failures are caused by the filter, not the topology")
    # Negative control for BOTH "blocked" assertions above. Without this, an
    # unreachable server, a missing route or a wrong address would produce the
    # exact same red-to-green result. Putting the blocked server's address
    # into the live allow-set is the single smallest change that removes the
    # filter's reason to drop -- everything else (routing, forwarding, nginx,
    # /etc/hosts) stays exactly as it was.
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

    # Prove the drop comes back when the allow-set entry goes away, so the
    # success above cannot be a one-way latch (e.g. a warmed ARP/conntrack
    # entry that would keep working regardless of the ruleset).
    refilter()

    if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)
    if not test_curl(vm, "http://${blockedIp}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)
    print("  OK: removing it again restores the block -- the allow-set is the")
    print("      discriminator, and the traffic really does transit the filter")

    print("\n[6.6/8] Confirming the packets enter the governed forward chain...")
    # Direct corroboration of the same fact: a counter at the head of the
    # per-interface forward chain must actually tick when the vm talks to a
    # server. If the vm were bypassing the gateway this stays at 0.
    hypervisor.succeed(f"nft insert rule {FWD_CHAIN} counter")
    vm.execute("curl -s --connect-timeout 5 --max-time 5 http://${blockedIp}/ 2>&1")
    vm.execute("curl -s --connect-timeout 5 --max-time 5 http://${allowedDomain}/ 2>&1")
    chain_out = hypervisor.succeed(f"nft list chain {FWD_CHAIN}")
    print(chain_out)
    counted = [int(m) for m in re.findall(r"counter packets (\d+)", chain_out)]
    assert counted and counted[0] > 0, \
        f"forward chain saw no packets -- vm traffic is bypassing it: {chain_out}"
    print(f"  OK: forward chain counted {counted[0]} packets from the vm")
    # The counter rule carries no verdict, so it changes nothing; the
    # redeploy simulation in [7.5/8] rebuilds the chain and drops it anyway.

    print("\n[7/8] Testing timer and nftables configuration...")
    timer_status = hypervisor.succeed("systemctl list-timers egress-filter-resolve-eth1.timer --no-pager")
    print("Timer status:")
    print(timer_status)
    assert "egress-filter-resolve-eth1.timer" in timer_status, "Timer not found"
    print("  OK: Timer is configured")

    ruleset = hypervisor.succeed("nft list table inet egress-filter")
    print("nftables ruleset:")
    print(ruleset)
    assert "drop" in ruleset, "drop rule not found"
    assert "egress_allow_eth1" in ruleset, "allow-set reference not found"
    assert "hook forward" in ruleset, "forward hook not found"
    print("  OK: nftables rules configured")

    # Redeploy simulation: re-run the setup unit (as a switch would) and
    # confirm the allow-set survives untouched -- this is the atomicity/
    # persistence guarantee the nftables port depends on.
    print("\n[7.5/8] Simulating a redeploy (chain teardown+rebuild)...")
    hypervisor.succeed("systemctl restart egress-filter-nftables.service")
    set_out_after_redeploy = hypervisor.succeed(f"nft list set {SET}")
    assert "${allowedIp}" in set_out_after_redeploy, "Allow-set lost its entries across a simulated redeploy!"
    print("  OK: allow-set entries survived a simulated redeploy")

    hypervisor.succeed("conntrack -F 2>/dev/null || true")
    if not test_curl(vm, "http://${allowedDomain}/", "ALLOWED_SUCCESS", should_succeed=True):
        sys.exit(1)
    if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)
    print("  OK: filtering still works after the simulated redeploy")

    print("\n[8/8] Verifying hypervisor can still access all servers...")
    hyp_result = hypervisor.succeed("curl -s --connect-timeout 5 http://${blockedIp}/")
    assert "BLOCKED_SUCCESS" in hyp_result, "Hypervisor should access blocked server"
    print("  OK: Hypervisor can access all servers directly")

    print("\n" + "=" * 60)
    print("ALL TESTS PASSED!")
    print("=" * 60)
    print("""
    Summary:
      - the vm is on its own subnet, routed to the servers only via the
        hypervisor, so its traffic really does transit the forward hook
      - every node holds exactly one address (no auto-assigned collisions)
      - nftables backend: resolve mode correctly populates the allow-set from DNS
      - VM can access allowed domain
      - VM cannot access blocked domain or direct IP -- and allow-listing the
        blocked address makes the SAME requests succeed, so the block is the
        filter's doing rather than the topology's
      - the governed forward chain provably counts the vm's packets
      - Timer is configured for periodic updates
      - nftables rules are correct
      - the allow-set survives a simulated redeploy (chain teardown+rebuild)
      - Hypervisor traffic is unaffected
    """)
  '';
}
