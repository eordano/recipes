# nixos-hardening-tiers
#
# Opt-in, stackable NixOS kernel/network hardening tiers.
#
# The whole point of this module is the *shape*, not the exact sysctls:
#
#   1. `config` MUST be `mkMerge [ ... ]` — an always-on block plus one
#      `mkIf` per tier. Do NOT chain the blocks with `//`. In Nix `//` is
#      right-biased attrset update, so `a // b // c` keeps only `c`; using it
#      here would silently discard every earlier block and turn the module
#      into a near-no-op that still evaluates cleanly and passes review.
#
#   2. Tiers stack. Any sysctl (or other key) set by more than one tier must
#      be deduped, or the two definitions collide when both tiers are enabled
#      on the same host. See the five net/vm keys shared by `basic` and
#      `advanced`: `advanced` only applies them `mkIf (!cfg.basic)`, and
#      `kernel.kptr_restrict` lives once in the always-block as a tri-state
#      value rather than being redefined per tier.
#
#   3. The always-on block owns non-optional mitigations (here, blacklisting
#      a vulnerable kernel module). No host can turn those off — they are not
#      guarded by any tier toggle.
#
# All tiers default OFF. Nothing here applies unless a host opts in.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkMerge
    types
    mkOption
    ;
  cfg = config.hardening;
in
{
  options.hardening = {
    antivirus = mkEnableOption "ClamAV antivirus daemon + updater";

    malloc = mkOption {
      description = "Enable a hardened memory allocator (scudo). Opt-in, off by default.";
      type = types.bool;
      default = false;
    };

    basic = mkOption {
      description = "Basic kernel/network measures. Opt-in, off by default.";
      type = types.bool;
      default = false;
    };

    medium = mkEnableOption "somewhat invasive kernel protection measures";

    advanced = mkEnableOption "pretty invasive kernel protection measures";

    # The `medium` tier locks kernel modules by default, which breaks hosts
    # that load out-of-tree modules at runtime (proprietary GPU drivers, DKMS,
    # etc.). Flip this on such hosts.
    allowKernelModuleLoading = mkOption {
      description = ''
        Keep runtime kernel module loading unlocked even under the `medium`
        tier. Enable on hosts that need to load modules after boot (e.g.
        out-of-tree GPU drivers or DKMS modules).
      '';
      type = types.bool;
      default = false;
    };
  };

  config = mkMerge [
    # ── Always-on block ─────────────────────────────────────────────────────
    # Applies to every host that imports this module, tiers or not. Put
    # non-optional mitigations here so no host can opt out.
    {
      services.clamav = mkIf cfg.antivirus {
        daemon.enable = true;
        updater.enable = true;
      };

      environment = mkIf cfg.malloc {
        memoryAllocator.provider = lib.mkDefault "scudo";
        variables.SCUDO_OPTIONS = lib.mkDefault "zero_contents=1";
      };

      boot = {
        # Example of a non-optional mitigation living outside the tiers.
        # Replace/extend with whatever module(s) you must never load. The
        # `install ... /bin/true` stub also defeats explicit `modprobe`.
        blacklistedKernelModules = [ "act_pedit" ];
        extraModprobeConfig = "install act_pedit ${pkgs.coreutils}/bin/true\n";

        # kptr_restrict is set by more than one tier, so it lives here ONCE as
        # a tri-state value instead of colliding across tier blocks.
        kernel.sysctl."kernel.kptr_restrict" = mkIf (cfg.basic || cfg.medium || cfg.advanced) (
          lib.mkForce (
            if cfg.advanced then
              2
            else if cfg.medium then
              1
            else
              2
          )
        );
      };
    }

    # ── basic tier ──────────────────────────────────────────────────────────
    (mkIf cfg.basic {
      security.unprivilegedUsernsClone = lib.mkDefault false;
      boot = {
        kernel.sysctl = {
          "net.core.bpf_jit_enable" = lib.mkDefault false;
          "kernel.sysrq" = lib.mkForce 0;

          # These five net/vm keys are ALSO wanted by `advanced`. They live
          # here in `basic`; `advanced` defers to `basic` (see below) so the
          # two tiers never define them twice on a host running both.
          "net.core.rmem_max" = lib.mkDefault 16777216;
          "net.core.wmem_max" = lib.mkDefault 16777216;
          "vm.min_free_kbytes" = lib.mkDefault 65536;

          "vm.swappiness" = lib.mkDefault 2;
          "vm.vfs_cache_pressure" = 30;
          "kernel.core_pattern" = "/var/crash/core.%u.%e.%p";
        };
        # Blacklist rarely-used, historically-buggy filesystem and legacy
        # network-protocol modules to shrink the kernel attack surface.
        blacklistedKernelModules = [
          "ax25"
          "netrom"
          "rose"
          "adfs"
          "affs"
          "bfs"
          "befs"
          "cramfs"
          "efs"
          "erofs"
          "exofs"
          "freevxfs"
          "f2fs"
          "hfs"
          "hpfs"
          "jfs"
          "minix"
          "nilfs2"
          "ntfs"
          "omfs"
          "qnx4"
          "qnx6"
          "sysv"
          "ufs"
        ];
      };
    })

    # ── medium tier ─────────────────────────────────────────────────────────
    (mkIf cfg.medium {
      security = {
        protectKernelImage = lib.mkDefault true;
        # Locking kernel modules breaks runtime module loading. Parameterized
        # so hosts that need it (GPU drivers, DKMS) can keep it unlocked.
        lockKernelModules = lib.mkDefault (!cfg.allowKernelModuleLoading);
      };
      boot = {
        consoleLogLevel = lib.mkOverride 500 3;

        kernel.sysctl = {
          "kernel.unprivileged_bpf_disabled" = lib.mkOverride 500 1;
          "net.core.bpf_jit_harden" = lib.mkForce 2;
          "kernel.yama.ptrace_scope" = lib.mkForce 2;
          "kernel.ftrace_enabled" = lib.mkDefault false;

          "kernel.randomize_va_space" = lib.mkForce 2;
          "fs.suid_dumpable" = lib.mkOverride 500 0;

          "kernel.dmesg_restrict" = lib.mkForce 1;
          "vm.unprivileged_userfaultfd" = lib.mkForce 0;

          "net.ipv4.tcp_syncookies" = lib.mkForce 1;
          "net.ipv4.tcp_syn_retries" = lib.mkForce 2;
          "net.ipv4.tcp_synack_retries" = lib.mkForce 2;
          "net.ipv4.tcp_max_syn_backlog" = lib.mkForce 4096;
          "net.ipv4.tcp_rfc1337" = lib.mkForce 1;
        };
        kernelParams = [
          "page_alloc.shuffle=1"
          "randomize_kstack_offset=on"
        ];
      };
    })

    # ── advanced tier ───────────────────────────────────────────────────────
    (mkIf cfg.advanced {
      security = {
        allowSimultaneousMultithreading = lib.mkDefault false;
        forcePageTableIsolation = lib.mkDefault true;
        virtualisation.flushL1DataCache = lib.mkDefault "always";
        apparmor.enable = lib.mkDefault true;
        apparmor.killUnconfinedConfinables = lib.mkDefault true;

        unprivilegedUsernsClone = config.virtualisation.containers.enable;
      };
      boot = {
        # These five keys overlap the `basic` tier verbatim. When both tiers
        # stack on one host, two definitions of the same sysctl collide — so
        # let `basic` own them and only apply here when `advanced` is the sole
        # tier. This `mkIf (!cfg.basic)` guard is the dedup.
        kernel.sysctl = lib.mkIf (!cfg.basic) {
          "net.core.bpf_jit_enable" = lib.mkDefault false;
          "kernel.sysrq" = lib.mkForce 0;

          "net.core.rmem_max" = lib.mkDefault 16777216;
          "net.core.wmem_max" = lib.mkDefault 16777216;
          "vm.min_free_kbytes" = lib.mkDefault 65536;
        };
        kernelParams = [
          "init_on_alloc=1"
          "init_on_free=1"
        ];
      };
    })
  ];
}
