{ pkgs, ... }:

let
  egressFilterModule = import ./default.nix;

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
          ${staticIp} ${staticAllowedDomain}
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
  name = "egress-filter-nftables-dnsmasq-test";

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
          allowedUDPPorts = [ 53 ];
          allowedTCPPorts = [ 53 ];
        };

        networking.extraHosts = ''
          ${allowedIp} ${allowedDomain}
          ${blockedIp} ${blockedDomain}
          ${staticIp} ${staticAllowedDomain}
        '';

        services.egressFilter = {
          enable = true;

          interfaces.eth1 = {
            enable = true;
            mode = "dnsmasq";

            domains = [
              allowedDomain
            ];

            allowedIPv4 = [
              staticIp
              allowedIp
            ];

            allowPrivateNetworks = false;
            allowDNS = true;

            dnsmasq = {
              listenAddress = hypervisorIp;
              port = 53;
              redirectDNS = true;
              extraConfig = ''
                no-hosts
                addn-hosts=/etc/hosts
              '';
            };
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

          nameservers = [ hypervisorIp ];
          firewall.enable = false;

          extraHosts = ''
            ${allowedIp} ${allowedDomain}
            ${blockedIp} ${blockedDomain}
            ${staticIp} ${staticAllowedDomain}
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

    static = mkTestServer {
      ip = staticIp;
      domain = staticAllowedDomain;
      name = "STATIC";
    };
  };

  testScript = ''
    import re
    import sys

    def test_curl(machine, url, expected_marker=None, should_succeed=True, timeout=10):
        """Helper to test curl and check results"""
        cmd = f"curl -s --connect-timeout {timeout} --max-time {timeout} {url} 2>&1"
        (status, output) = machine.execute(cmd)

        if should_succeed:
            if status != 0:
                print(f"FAIL: curl to {url} failed with status {status}")
                print(f"Output: {output}")
                return False
            if expected_marker and expected_marker not in output:
                print(f"FAIL: Expected marker '{expected_marker}' not found in response")
                print(f"Output: {output}")
                return False
            print(f"OK: Successfully accessed {url}")
            return True
        else:
            if status == 0 and expected_marker and expected_marker in output:
                print(f"FAIL: Should not have been able to access {url}")
                print(f"Output: {output}")
                return False
            print(f"OK: Access to {url} blocked as expected")
            return True

    print("=" * 60)
    print("EGRESS FILTER TEST - NFTABLES BACKEND, DNSMASQ MODE")
    print("=" * 60)

    start_all()

    print("\n[1/8] Waiting for nodes to be ready...")
    hypervisor.wait_for_unit("multi-user.target", timeout=60)
    vm.wait_for_unit("multi-user.target", timeout=60)
    allowed.wait_for_unit("multi-user.target", timeout=60)
    blocked.wait_for_unit("multi-user.target", timeout=60)
    static.wait_for_unit("multi-user.target", timeout=60)

    hypervisor.wait_for_unit("nftables.service", timeout=30)
    hypervisor.wait_for_unit("egress-filter-nftables.service", timeout=30)
    hypervisor.wait_for_unit("egress-filter-dnsmasq-eth1.service", timeout=60)
    allowed.wait_for_unit("nginx.service", timeout=30)
    blocked.wait_for_unit("nginx.service", timeout=30)
    static.wait_for_unit("nginx.service", timeout=30)

    print("  Waiting for network interfaces to be configured...")
    hypervisor.wait_until_succeeds("ip addr show eth1 | grep '${hypervisorIp}'", timeout=15)
    hypervisor.wait_until_succeeds("ip addr show eth2 | grep '${hypervisorServerIp}'", timeout=15)
    vm.wait_until_succeeds("ip addr show eth1 | grep '${vmIp}'", timeout=15)
    allowed.wait_until_succeeds("ip addr show eth1 | grep '${allowedIp}'", timeout=15)
    blocked.wait_until_succeeds("ip addr show eth1 | grep '${blockedIp}'", timeout=15)
    static.wait_until_succeeds("ip addr show eth1 | grep '${staticIp}'", timeout=15)
    print("All nodes ready")

    print("\n[2/8] Testing basic network connectivity...")
    allowed.wait_until_succeeds("ping -c 1 ${hypervisorServerIp}", timeout=15)
    vm.wait_until_succeeds("ping -c 1 ${hypervisorIp}", timeout=15)
    print("Basic connectivity OK")

    # Standing guards for the two topology bugs described at the top of this
    # file, so neither can silently come back.
    for (machine, iface, want) in [
        (hypervisor, "eth1", "${hypervisorIp}"),
        (hypervisor, "eth2", "${hypervisorServerIp}"),
        (vm, "eth1", "${vmIp}"),
        (allowed, "eth1", "${allowedIp}"),
        (blocked, "eth1", "${blockedIp}"),
        (static, "eth1", "${staticIp}"),
    ]:
        addrs = machine.succeed(
            f"ip -4 -o addr show dev {iface} | awk '{{print $4}}'"
        ).split()
        assert addrs == [f"{want}/24"], \
            f"{iface} should hold exactly [{want}/24], holds {addrs}"
    print("  OK: no auto-assigned extra addresses (bug 1 guard)")

    for dest in ["${allowedIp}", "${blockedIp}", "${staticIp}"]:
        route = vm.succeed(f"ip route get {dest}").strip()
        assert "via ${hypervisorIp}" in route, \
            f"vm must reach {dest} via the gateway, got: {route}"
    print("  OK: vm reaches every server only via the hypervisor (bug 2 guard)")

    print("\n[3/8] Testing DNS resolution (via the nat-hook DNAT redirect)...")
    # Assert dnsmasq is bound to the SPECIFIC address the client below is
    # about to query, not merely that *something* holds port 53 -- a gate
    # that only checked ":53" would pass even if dnsmasq had bound the wrong
    # address (or nothing reachable from the vm at all).
    hypervisor.wait_until_succeeds(
        "ss -lunp | grep -F '${hypervisorIp}:53'", timeout=30
    )
    hypervisor.wait_until_succeeds(
        "ss -ltnp | grep -F '${hypervisorIp}:53'", timeout=30
    )

    # A one-shot dig can still lose a race against dnsmasq's very first
    # startup tick or the vm's ARP entry for the hypervisor settling, so this
    # retries for up to 60s rather than asserting on the first attempt. This
    # is genuine startup jitter, not the address collision the top-of-file
    # note describes (that one is fixed by `assignIP = false` above, not by
    # retrying) -- ping already exercised and warmed the same ARP path in
    # step [2/8], so in practice this succeeds on the first try.
    vm.wait_until_succeeds(
        "dig +short +time=2 +tries=1 @${hypervisorIp} ${allowedDomain}", timeout=60
    )

    # The VM's resolver is the hypervisor's real listenAddress; there is no
    # DNAT visible from the VM's own point of view (DNAT rewrites at the
    # hypervisor), but this still proves eth1 traffic reaches the dnsmasq
    # interceptor and gets a real answer -- which is what feeds the nftset.
    allowed_resolved = vm.succeed("dig +short +time=2 +tries=2 @${hypervisorIp} ${allowedDomain}").strip()
    blocked_resolved = vm.succeed("dig +short +time=2 +tries=2 @${hypervisorIp} ${blockedDomain}").strip()
    static_resolved = vm.succeed("dig +short +time=2 +tries=2 @${hypervisorIp} ${staticAllowedDomain}").strip()

    print(f"  ${allowedDomain} -> {allowed_resolved}")
    print(f"  ${blockedDomain} -> {blocked_resolved}")
    print(f"  ${staticAllowedDomain} -> {static_resolved}")

    assert allowed_resolved == "${allowedIp}", f"DNS mismatch for allowed: {allowed_resolved}"
    assert blocked_resolved == "${blockedIp}", f"DNS mismatch for blocked: {blocked_resolved}"
    assert static_resolved == "${staticIp}", f"DNS mismatch for static: {static_resolved}"
    print("DNS resolution OK")

    print("\n[4/8] Checking nftables allow-set state (static seed)...")
    hypervisor.sleep(1)
    set_out = hypervisor.succeed("nft list set inet egress-filter egress_allow_eth1")
    print(f"set contents:\n{set_out}")

    assert "${allowedIp}" in set_out, "Allowed IP not in the allow-set!"
    print("  OK: ${allowedIp} is in the allow-set (static seed -- see the")
    print("      allowedIPv4 comment above for why this isn't dnsmasq's")
    print("      live --nftset= path in this offline VM environment)")

    assert "${staticIp}" in set_out, "Static IP not in the allow-set!"
    print("  OK: ${staticIp} is in the allow-set (static seed)")

    assert "${blockedIp}" not in set_out, "Blocked IP should not be in the allow-set!"
    print("  OK: ${blockedIp} is NOT in the allow-set")

    print("\n[5/8] Testing HTTP access from VM...")

    print("  Testing allowed domain...")
    if not test_curl(vm, "http://${allowedDomain}/", "ALLOWED_SUCCESS", should_succeed=True):
        sys.exit(1)

    print("  Testing static allowed IP...")
    if not test_curl(vm, "http://${staticAllowedDomain}/", "STATIC_SUCCESS", should_succeed=True):
        sys.exit(1)

    print("  Testing blocked domain (should fail)...")
    if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)

    print("  Testing direct IP access to blocked server (should fail)...")
    if not test_curl(vm, "http://${blockedIp}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)

    print("\n[5.5/8] ...and those failures are caused by the filter, not the topology")
    # Negative control for BOTH "blocked" assertions above (pattern from
    # tests/exit-node-masquerade.nix, subtest "...and that failure is caused
    # by the scoping, not the topology"). An unreachable server, a missing
    # route, or a wrong address would produce exactly the same green result,
    # so a block is only meaningful if removing the filter's reason to drop
    # -- and nothing else -- makes the SAME request succeed.
    SET = "inet egress-filter egress_allow_eth1"
    hypervisor.succeed(f"nft add element {SET} '{{ ${blockedIp} }}'")
    hypervisor.succeed("conntrack -F 2>/dev/null || true")

    if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=True):
        print("FAIL: with ${blockedIp} in the allow-set the SAME request still")
        print("      failed -- the earlier 'blocked' results were topology, not")
        print("      the egress filter.")
        sys.exit(1)
    if not test_curl(vm, "http://${blockedIp}/", "BLOCKED_SUCCESS", should_succeed=True):
        print("FAIL: direct-IP request still failed with ${blockedIp} allowed.")
        sys.exit(1)
    print("  OK: allow-listing the blocked server makes both requests succeed")

    # Rebuild the set through the module's own path (flush, then let the
    # setup unit re-seed the static allowedIPv4 entries) so the success above
    # cannot be a one-way latch from a warmed ARP/conntrack entry.
    hypervisor.succeed(f"nft flush set {SET}")
    hypervisor.succeed("systemctl restart egress-filter-nftables.service")
    hypervisor.succeed("conntrack -F 2>/dev/null || true")
    set_out = hypervisor.succeed(f"nft list set {SET}")
    assert "${blockedIp}" not in set_out, f"allow-set still holds ${blockedIp}:\n{set_out}"
    assert "${allowedIp}" in set_out, f"static seed lost after rebuild:\n{set_out}"

    if not test_curl(vm, "http://${blockedDomain}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)
    if not test_curl(vm, "http://${blockedIp}/", "BLOCKED_SUCCESS", should_succeed=False):
        sys.exit(1)
    if not test_curl(vm, "http://${allowedDomain}/", "ALLOWED_SUCCESS", should_succeed=True):
        sys.exit(1)
    print("  OK: removing it again restores the block -- the allow-set is the")
    print("      discriminator, and the traffic really does transit the filter")

    print("\n[5.6/8] Confirming the packets enter the governed forward chain...")
    FWD_CHAIN = "inet egress-filter egress_fwd_eth1"
    hypervisor.succeed(f"nft insert rule {FWD_CHAIN} counter")
    vm.execute("curl -s --connect-timeout 5 --max-time 5 http://${blockedIp}/ 2>&1")
    vm.execute("curl -s --connect-timeout 5 --max-time 5 http://${allowedDomain}/ 2>&1")
    chain_out = hypervisor.succeed(f"nft list chain {FWD_CHAIN}")
    print(chain_out)
    counted = [int(m) for m in re.findall(r"counter packets (\d+)", chain_out)]
    assert counted and counted[0] > 0, \
        f"forward chain saw no packets -- vm traffic is bypassing it: {chain_out}"
    print(f"  OK: forward chain counted {counted[0]} packets from the vm")
    hypervisor.succeed("systemctl restart egress-filter-nftables.service")

    print("\n[6/8] Verifying a guest cannot bypass DNS interception via an outside resolver...")
    # Port 53 from eth1 is unconditionally DNATed to the local dnsmasq, so a
    # query "to" 8.8.8.8 actually lands on the interceptor and still only
    # resolves what's on the allowlist. This IS the anti-bypass guarantee
    # (see the README): the guest cannot reach a real outside resolver.
    bypass_attempt = vm.succeed("dig +short +time=2 +tries=2 @8.8.8.8 ${allowedDomain} || true").strip()
    print(f"  Attempted direct query to 8.8.8.8: got '{bypass_attempt}'")
    assert bypass_attempt == "${allowedIp}", "DNS bypass query did not land on the interceptor as expected"
    print("  OK: DNS to an outside resolver is transparently redirected to the interceptor")

    print("\n[7/8] Verifying hypervisor can still access all servers...")
    hyp_result = hypervisor.succeed("curl -s --connect-timeout 5 http://${blockedIp}/")
    assert "BLOCKED_SUCCESS" in hyp_result, "Hypervisor should access blocked server"
    print("  OK: Hypervisor can access all servers directly")

    print("\n[8/8] Testing nftables rules and dnsmasq service...")
    ruleset = hypervisor.succeed("nft list table inet egress-filter")
    print("nftables ruleset:")
    print(ruleset)
    assert "drop" in ruleset, "drop rule not found"
    assert "egress_allow_eth1" in ruleset, "allow-set reference not found"
    assert "dnat" in ruleset, "DNAT rule not found"
    assert "hook prerouting" in ruleset, "nat prerouting hook not found"
    assert "hook forward" in ruleset, "forward hook not found"
    print("  OK: nftables rules configured correctly")

    dnsmasq_status = hypervisor.succeed("systemctl is-active egress-filter-dnsmasq-eth1.service")
    assert "active" in dnsmasq_status, "dnsmasq service not running"
    print("  OK: dnsmasq service is running")

    print("\n" + "=" * 60)
    print("ALL TESTS PASSED!")
    print("=" * 60)
    print("")
    print("Summary:")
    print("  - nftables backend: dnsmasq mode's nat-hook DNAT redirect works")
    print("  - VM can access servers with allowed/static IPs")
    print("  - VM cannot access servers with blocked IPs -- and allow-listing")
    print("    the blocked address makes the SAME requests succeed, so the")
    print("    block is the filter's doing rather than the topology's")
    print("  - the governed forward chain provably counts the vm's packets")
    print("  - a guest cannot bypass DNS interception via an outside resolver")
    print("  - Hypervisor traffic is unaffected")
    print("  - nftables rules are properly configured")
    print("  - dnsmasq service is running")
    print("")
    print("Note: dnsmasq's live --nftset= population is not exercised end-to-end")
    print("here (same limitation as the iptables sibling test's ipset= note):")
    print("this offline VM environment has no real upstream resolver, so")
    print("allowedDomain only ever resolves via /etc/hosts, and dnsmasq's")
    print("ipset/nftset hooks fire on upstream replies, not hosts-file hits.")
    print("The --nftset= directive syntax itself is verified independently")
    print("against the real dnsmasq binary and source -- see the README.")
  '';
}
