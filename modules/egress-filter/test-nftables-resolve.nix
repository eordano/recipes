{ pkgs, ... }:

let
  t = import ./nftables-vm.nix { inherit pkgs; };
  inherit (t)
    allowedDomain
    blockedDomain
    hypervisorIp
    hypervisorServerIp
    vmIp
    allowedIp
    blockedIp
    ;
in
pkgs.testers.nixosTest {
  name = "egress-filter-nftables-resolve-test";

  nodes = t.servers // {
    inherit (t) vm;
    hypervisor = {
      imports = [
        (import ./default.nix)
        t.hypervisor
      ];

      services.egressFilter = {
        enable = true;
        updateInterval = "1m";

        interfaces.eth1 = {
          enable = true;
          mode = "resolve";
          domains = [ allowedDomain ];
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
    };
  };

  testScript = t.py + ''
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
    assert_topology([(allowed, "${allowedIp}"), (blocked, "${blockedIp}")], ["${allowedIp}", "${blockedIp}"])

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
    assert_blocked_by_the_filter(refilter)

    print("\n[6.6/8] Confirming the packets enter the governed forward chain...")
    assert_forward_chain_counts()
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
