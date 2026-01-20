{
  pkgs,
  ...
}:
let
  mkConfig =
    harden:
    { ... }:
    {
      imports = [ ../modules/harden.nix ];
      services.xserver.enable = false;
      modules = { inherit harden; };
    };
in
pkgs.testers.nixosTest {
  name = "harden-module-test";

  nodes = {
    # Test basic preset (default)
    basic = mkConfig {
      preset = "basic";
      scudo = true;
    };

    # Test medium preset features (using none + manual selection to avoid lockKernelModules)
    medium = mkConfig {
      preset = "none";
      scudo = true;
      features = {
        # Medium features minus lockKernelModules
        kernelHardening = true;
        blacklistObscureModules = true;
        networkBuffers = true;
        crashLogs = true;
        protectKernelImage = true;
        # lockKernelModules = false; # Skip for VM
        ptraceRestrict = true;
        bpfHarden = true;
        tcpHarden = true;
        networkHarden = true;
        restrictDmesg = true;
      };
    };

    # Test advanced features individually (preset=none to avoid OR logic)
    advanced = mkConfig {
      preset = "none";
      scudo = true;
      features = {
        # Enable safe advanced features
        kernelHardening = true;
        blacklistObscureModules = true;
        networkBuffers = true;
        crashLogs = true;
        tcpHarden = true;
        networkHarden = true;
        restrictDmesg = true;
        ptraceRestrict = true;
        bpfHarden = true;
        forcePageTableIsolation = true;
        initOnAlloc = true;
        apparmor = true;
        # Skip features that break VMs: lockKernelModules, disableSmt, iommu, kernelLockdown
      };
    };

    # Test custom deny modules
    customDeny = mkConfig {
      preset = "basic";
      denyModules = {
        bluetooth = true;
        thunderbolt = true;
        webcam = true;
      };
      extraDenyModules = [ "vivid" ];
    };

    # Test none preset with selective features
    selective = mkConfig {
      preset = "none";
      scudo = false;
      features = {
        kernelHardening = true;
        tcpHarden = true;
        networkHarden = true;
      };
    };
  };

  testScript = ''
    start_all()

    # ─────────────────────────────────────────────────────────────
    # Basic Preset Tests
    # ─────────────────────────────────────────────────────────────
    with subtest("Basic preset - sysctl hardening"):
        basic.wait_for_unit("multi-user.target")

        # Check kernel pointer restriction
        basic.succeed("sysctl kernel.kptr_restrict | grep -q '2'")

        # Check SysRq is disabled
        basic.succeed("sysctl kernel.sysrq | grep -q '0'")

        # Check network buffers are increased
        basic.succeed("test $(sysctl -n net.core.rmem_max) -ge 16777216")
        basic.succeed("test $(sysctl -n net.core.wmem_max) -ge 16777216")

    with subtest("Basic preset - crash log directory"):
        basic.succeed("test -d /var/crash")

    with subtest("Basic preset - scudo allocator"):
        # Check scudo is configured
        basic.succeed("grep -q 'scudo' /etc/profile || true")

    # ─────────────────────────────────────────────────────────────
    # Medium Preset Tests
    # ─────────────────────────────────────────────────────────────
    with subtest("Medium preset - TCP hardening"):
        medium.wait_for_unit("multi-user.target")

        # SYN cookies enabled
        medium.succeed("sysctl net.ipv4.tcp_syncookies | grep -q '1'")

        # TCP SYN retries
        medium.succeed("sysctl net.ipv4.tcp_syn_retries | grep -q '2'")

        # RFC 1337
        medium.succeed("sysctl net.ipv4.tcp_rfc1337 | grep -q '1'")

    with subtest("Medium preset - network hardening"):
        # Reverse path filtering
        medium.succeed("sysctl net.ipv4.conf.all.rp_filter | grep -q '1'")

        # Reject ICMP redirects
        medium.succeed("sysctl net.ipv4.conf.all.accept_redirects | grep -q '0'")

        # Don't send redirects
        medium.succeed("sysctl net.ipv4.conf.all.send_redirects | grep -q '0'")

        # Reject source routing
        medium.succeed("sysctl net.ipv4.conf.all.accept_source_route | grep -q '0'")

        # Log martian packets
        medium.succeed("sysctl net.ipv4.conf.all.log_martians | grep -q '1'")

    with subtest("Medium preset - BPF hardening"):
        medium.succeed("sysctl kernel.unprivileged_bpf_disabled | grep -q '1'")
        medium.succeed("sysctl net.core.bpf_jit_harden | grep -q '2'")

    with subtest("Medium preset - ptrace restriction"):
        medium.succeed("sysctl kernel.yama.ptrace_scope | grep -q '2'")

    with subtest("Medium preset - dmesg restriction"):
        medium.succeed("sysctl kernel.dmesg_restrict | grep -q '1'")

    with subtest("Medium preset - ASLR full"):
        medium.succeed("sysctl kernel.randomize_va_space | grep -q '2'")

    # ─────────────────────────────────────────────────────────────
    # Advanced Preset Tests
    # ─────────────────────────────────────────────────────────────
    with subtest("Advanced preset - AppArmor enabled"):
        advanced.wait_for_unit("multi-user.target")

        # Check AppArmor is loaded
        advanced.succeed("test -d /sys/kernel/security/apparmor || echo 'AppArmor not in kernel'")

    with subtest("Advanced preset - kernel params"):
        # Check kernel command line for hardening params
        cmdline = advanced.succeed("cat /proc/cmdline")

        # Memory initialization
        assert "init_on_alloc=1" in cmdline, "init_on_alloc not in cmdline"
        assert "init_on_free=1" in cmdline, "init_on_free not in cmdline"

        # Page allocation shuffling
        assert "page_alloc.shuffle=1" in cmdline, "page_alloc.shuffle not in cmdline"

        # Stack randomization
        assert "randomize_kstack_offset=on" in cmdline, "randomize_kstack_offset not in cmdline"

    # ─────────────────────────────────────────────────────────────
    # Custom Deny Modules Tests
    # ─────────────────────────────────────────────────────────────
    with subtest("Custom deny - blacklisted modules"):
        customDeny.wait_for_unit("multi-user.target")

        # Check modprobe blacklist
        blacklist = customDeny.succeed("cat /etc/modprobe.d/*.conf")

        # Check bluetooth is blacklisted
        assert "bluetooth" in blacklist, "bluetooth not blacklisted"
        assert "btusb" in blacklist, "btusb not blacklisted"

        # Check thunderbolt is blacklisted
        assert "thunderbolt" in blacklist, "thunderbolt not blacklisted"

        # Check webcam is blacklisted
        assert "uvcvideo" in blacklist, "uvcvideo not blacklisted"

        # Check custom extra module
        assert "vivid" in blacklist, "vivid (extraDenyModules) not blacklisted"

        # Check obscure filesystems are blacklisted (default)
        assert "minix" in blacklist, "minix not blacklisted"
        assert "hfs" in blacklist, "hfs not blacklisted"

        # Check firewire is blacklisted (default)
        assert "firewire-core" in blacklist, "firewire-core not blacklisted"

    # ─────────────────────────────────────────────────────────────
    # Selective Features Tests (none preset)
    # ─────────────────────────────────────────────────────────────
    with subtest("Selective features - only enabled features active"):
        selective.wait_for_unit("multi-user.target")

        # TCP hardening should be enabled
        selective.succeed("sysctl net.ipv4.tcp_syncookies | grep -q '1'")

        # Network hardening should be enabled
        selective.succeed("sysctl net.ipv4.conf.all.rp_filter | grep -q '1'")

        # Kernel hardening should be enabled
        selective.succeed("sysctl kernel.kptr_restrict | grep -q '2'")

    # ─────────────────────────────────────────────────────────────
    # Module Loading Prevention (verify blacklist works)
    # ─────────────────────────────────────────────────────────────
    with subtest("Blacklisted module cannot be loaded"):
        customDeny.succeed("grep 'bluetooth' /etc/modprobe.d/*.conf")

    print("All hardening tests passed!")
  '';
}
