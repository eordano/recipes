{ pkgs, ... }:

let
  t = import ./nftables-vm.nix {
    inherit pkgs;
    withStatic = true;
  };
  inherit (t)
    allowedDomain
    blockedDomain
    staticAllowedDomain
    hypervisorIp
    hypervisorServerIp
    vmIp
    allowedIp
    blockedIp
    staticIp
    ;
in
pkgs.testers.nixosTest {
  name = "egress-filter-nftables-dnsmasq-test";

  nodes = t.servers // {
    vm = {
      imports = [ t.vm ];
      networking.nameservers = [ hypervisorIp ];
    };
    hypervisor = {
      imports = [
        (import ./default.nix)
        t.hypervisor
      ];

      networking.firewall = {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 53 ];
      };

      services.egressFilter = {
        enable = true;

        interfaces.eth1 = {
          enable = true;
          mode = "dnsmasq";
          domains = [ allowedDomain ];
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
    };
  };

  testScript = t.py + ''
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

    assert_topology(
        [(allowed, "${allowedIp}"), (blocked, "${blockedIp}"), (static, "${staticIp}")],
        ["${allowedIp}", "${blockedIp}", "${staticIp}"],
    )

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
    # is genuine startup jitter, not the address collision
    # nftables-vm.nix describes (that one is fixed by `assignIP = false`, not by
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
    set_out = hypervisor.succeed(f"nft list set {SET}")
    print(f"set contents:\n{set_out}")

    assert "${allowedIp}" in set_out, "Allowed IP not in the allow-set!"
    print("  OK: ${allowedIp} is in the allow-set (static seed; see the note at the end)")

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
    def refilter():
        # Flush, then let the setup unit re-seed the static allowedIPv4 entries.
        hypervisor.succeed(f"nft flush set {SET}")
        hypervisor.succeed("systemctl restart egress-filter-nftables.service")
        hypervisor.succeed("conntrack -F 2>/dev/null || true")
        set_out = hypervisor.succeed(f"nft list set {SET}")
        assert "${blockedIp}" not in set_out, f"allow-set still holds ${blockedIp}:\n{set_out}"
        assert "${allowedIp}" in set_out, f"static seed lost after rebuild:\n{set_out}"

    assert_blocked_by_the_filter(refilter)
    if not test_curl(vm, "http://${allowedDomain}/", "ALLOWED_SUCCESS", should_succeed=True):
        sys.exit(1)

    print("\n[5.6/8] Confirming the packets enter the governed forward chain...")
    assert_forward_chain_counts()
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
