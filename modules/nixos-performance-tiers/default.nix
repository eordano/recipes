{
  lib,
  config,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;
  cfg = config.tuning;
  t = cfg.tradeoffs;

  hasDiskSwap = config.swapDevices != [ ];
  hasZfs = builtins.any (fs: fs.fsType == "zfs") (builtins.attrValues config.fileSystems);

  jitValue = config.boot.kernel.sysctl."net.core.bpf_jit_enable" or true;
  jitEnabled =
    !(builtins.elem jitValue [
      false
      0
      "0"
    ]);
in
{
  options.tuning = {
    enable = mkEnableOption "workload-class performance tuning baseline";

    role = mkOption {
      description = ''
        Coarse workload class. Sets DEFAULTS ONLY — every knob under
        `tuning.{cpu,memory,storage}` stays independently overridable, and the
        CPU-mitigation trade-offs are never implied by role.
      '';
      type = types.enum [
        "builder"
        "services"
        "workstation"
        "hypervisor"
      ];
      default = "services";
    };

    tradeoffs = {
      smt = mkOption {
        description = ''
          Simultaneous multithreading. `null` inherits whatever a hardening
          tier decided (hardening profiles typically `mkDefault false` it).
          Set `true` on build hosts whose `nix.settings.cores` was sized for
          the SMT-on thread count; `false` only where hostile local code shares
          a physical core.
        '';
        type = types.nullOr types.bool;
        default = null;
      };

      pti = mkOption {
        description = ''
          Force page-table isolation even on CPUs that report themselves
          Meltdown-safe. Inert on AMD Zen; real value on hosts running
          untrusted workloads that rely on address-space isolation.
        '';
        type = types.nullOr types.bool;
        default = null;
      };

      l1dFlush = mkOption {
        description = ''
          `kvm-intel` vmentry L1D flush. Inert under `kvm-amd`. Keep "always"
          on hypervisors running untrusted guests.
        '';
        type = types.nullOr (
          types.enum [
            "never"
            "cond"
            "always"
          ]
        );
        default = null;
      };

      ioUring = mkOption {
        description = ''
          `false` sets `kernel.io_uring_disabled = 2`. A real regression for
          anything that uses io_uring (modern databases, proxies, some
          container runtimes); `null` leaves the kernel default alone.
        '';
        type = types.nullOr types.bool;
        default = null;
      };

      schedExt = mkOption {
        description = ''
          `services.scx.scheduler` to run, e.g. "scx_lavd" or "scx_rusty".
          Desktop/latency win only — leave `null` on headless hosts. REQUIRES
          the BPF JIT, which hardening tiers commonly disable; asserted below.
          Values are validated by `services.scx.scheduler` itself.
        '';
        type = types.nullOr types.str;
        default = null;
        example = "scx_lavd";
      };
    };

    cpu = {
      governor = mkOption {
        description = ''
          `powerManagement.cpuFreqGovernor`. `null` keeps the kernel default
          (schedutil / amd-pstate-EPP), which already reaches maximum clocks
          under sustained load — pin "performance" only on headless machines
          where idle watts and fan noise do not matter. Applied with
          `mkDefault` so a host that already states a governor keeps it.
        '';
        type = types.nullOr types.str;
        default = if cfg.role == "builder" then "performance" else null;
        defaultText = lib.literalExpression ''if role == "builder" then "performance" else null'';
      };

      slabNoMerge = mkOption {
        description = ''
          Add `slab_nomerge` to the kernel command line. Buys slab
          cache-separation without the SLUB debug slowpath.
        '';
        type = types.bool;
        default = true;
      };

      slabDebug = mkEnableOption "slub_debug=FZP slab debugging (DEBUG ONLY, hot-path tax)";
    };

    memory = {
      zram = {
        enable = mkOption {
          description = ''
            Enable zram swap. Applied with `mkDefault`, so a host (or another
            module) that already decides this keeps the last word.
          '';
          type = types.bool;
          default = true;
        };

        memoryPercent = mkOption {
          description = ''
            Percentage of RAM handed to zram. 25 only where a disk backstop
            exists; where zram is the ONLY swap device, shrinking it RAISES
            OOM risk on exactly the hosts that already OOM under build load,
            so the default inverts to 50.
          '';
          type = types.ints.positive;
          default = if hasDiskSwap then 25 else 50;
          defaultText = lib.literalExpression "if config.swapDevices != [ ] then 25 else 50";
        };
      };

      swappiness = mkOption {
        description = ''
          `vm.swappiness`. 180 is the zram-only number (swapping to compressed
          RAM is cheaper than reclaiming page cache); the presence of ANY disk
          swap caps this at 150 so a RAM win does not turn into NAND wear.
          Applied as a PLAIN assignment — see the README: this is the one knob
          that must out-rank a hardening tier's `mkDefault 2`.
        '';
        type = types.int;
        default = if hasDiskSwap then 150 else 180;
        defaultText = lib.literalExpression "if config.swapDevices != [ ] then 150 else 180";
      };

      pageCluster = mkOption {
        description = ''
          `vm.page-cluster`. The kernel default of 3 faults in 2^3 = 8 pages
          per swap-in to amortise seek cost. When the swap device is RAM there
          is no seek cost, so the readahead is pure decompression waste — 0
          reads exactly the faulting page.
        '';
        type = types.int;
        default = 0;
      };

      watermarkBoostFactor = mkOption {
        description = ''
          `vm.watermark_boost_factor`. 0 disables the external-fragmentation
          reclaim boost, which is counterproductive when swap is compressed
          RAM.
        '';
        type = types.int;
        default = 0;
      };

      watermarkScaleFactor = mkOption {
        description = ''
          `vm.watermark_scale_factor`. Higher values start reclaim earlier and
          in smaller steps — what you want when the swap device is compressed
          RAM rather than a disk.
        '';
        type = types.int;
        default = 125;
      };

      arcMaxBytes = mkOption {
        description = ''
          ZFS ARC cap, in bytes. MUST be set per host from the actual installed
          RAM — there is no safe fleet-wide default and a guessed cap can OOM a
          production host, so this defaults to `null`. `null` leaves ARC
          uncapped, which means roughly 50% of physical memory and puts ARC in
          direct competition with databases, passthrough VMs, inference
          runtimes and zram.
        '';
        type = types.nullOr types.int;
        default = null;
        example = 34359738368;
      };
    };

    storage = {
      manageZfs = mkOption {
        description = ''
          Apply the ZFS scrub/trim policy below on hosts that have at least one
          `fsType = "zfs"` filesystem. Set `false` to keep the CPU/memory
          tuning without touching storage policy.
        '';
        type = types.bool;
        default = true;
      };

      scrubInterval = mkOption {
        description = ''
          `services.zfs.autoScrub.interval`. Applied with `mkDefault`, so a
          host (or a disko config) that already states its own interval keeps
          it instead of colliding.
        '';
        type = types.str;
        default = "monthly";
      };

      disableFstrim = mkOption {
        description = ''
          Set `services.fstrim.enable = mkDefault false` on ZFS hosts, because
          `services.zfs.trim` is the mechanism that actually works there. See
          the README — this is a `mkDefault` assignment rather than an
          assertion on purpose.
        '';
        type = types.bool;
        default = true;
      };

      noSnapshotPaths = mkOption {
        description = ''
          Datasets whose contents are reproducible or self-caching and which
          should NOT be on the auto-snapshot rotation.

          DOCUMENTATION ONLY — this option emits NO configuration. ZFS dataset
          properties are live state: disko `options` apply at pool-create time
          and disko never re-runs on an installed host, so the real change is
          `zfs set com.sun:auto-snapshot=false <pool>/<dataset>` plus
          destroying the snapshots that already accumulated. Record the intent
          here, then make it true on the host and in its disko file.
        '';
        type = types.listOf types.str;
        default = [
          "/nix"
          "/var/lib/docker"
        ];
      };
    };

    hardeningTier = {
      basic = mkOption {
        description = ''
          Whether this workload class wants the cheap hardening tier. Almost
          always yes: legacy-filesystem module blacklists, kernel image
          protection, ptrace/dmesg restrictions and TCP SYN-flood hardening
          cost effectively nothing.
        '';
        type = types.bool;
        default = true;
      };

      medium = mkOption {
        description = ''
          Whether this workload class wants the moderately invasive hardening
          tier. Off on workstations: `kernel.yama.ptrace_scope = 2` breaks
          non-root gdb/strace and ptrace-platform sandboxes, so a developer
          machine should opt in deliberately.
        '';
        type = types.bool;
        default = cfg.role != "workstation";
        defaultText = lib.literalExpression ''role != "workstation"'';
      };

      apply = mkOption {
        description = ''
          Drive `hardening.basic` / `hardening.medium` (the option surface of
          the `nixos-hardening-tiers` recipe) from the two values above, with
          `mkDefault`. Leave `false` if your hardening options live under a
          different attribute path — read `tuning.hardeningTier.{basic,medium}`
          yourself and forward them.
        '';
        type = types.bool;
        default = false;
      };

      unlockKernelModules = mkOption {
        description = ''
          Force `security.lockKernelModules = false`. Applied at
          `mkOverride 900` — see the README; `mkDefault` would be a CONFLICT,
          `mkForce` would make it unoverridable by the host.
        '';
        type = types.bool;
        default = cfg.role == "workstation";
        defaultText = lib.literalExpression ''role == "workstation"'';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = t.schedExt == null || jitEnabled;
          message = ''
            tuning.tradeoffs.schedExt requires the BPF JIT. Hardening tiers
            commonly set net.core.bpf_jit_enable = false, and with the JIT off
            the scx unit starts, fails to attach its struct_ops program and
            burns through its restart limit — a dead unit, not a visible
            error. Either drop scx or explicitly re-enable the JIT and accept
            that hardening regression.
          '';
        }
      ];
    }

    # ── CPU ────────────────────────────────────────────────────────────────
    (mkIf (cfg.cpu.governor != null) {
      powerManagement.cpuFreqGovernor = lib.mkDefault cfg.cpu.governor;
    })

    # Trade-offs are PLAIN assignments (priority 100): they must beat a
    # hardening tier's mkDefault without reaching for mkForce. A `null`
    # trade-off emits nothing at all, which is the difference between
    # "inherit the tier's decision" and "override it to the same value".
    (mkIf (t.smt != null) { security.allowSimultaneousMultithreading = t.smt; })
    (mkIf (t.pti != null) { security.forcePageTableIsolation = t.pti; })
    (mkIf (t.l1dFlush != null) { security.virtualisation.flushL1DataCache = t.l1dFlush; })
    (mkIf (t.ioUring == false) { boot.kernel.sysctl."kernel.io_uring_disabled" = 2; })
    (mkIf (t.schedExt != null) {
      services.scx = {
        enable = true;
        scheduler = t.schedExt;
      };
    })

    (mkIf cfg.cpu.slabDebug { boot.kernelParams = [ "slub_debug=FZP" ]; })
    (mkIf cfg.cpu.slabNoMerge { boot.kernelParams = [ "slab_nomerge" ]; })

    # ── Memory ─────────────────────────────────────────────────────────────
    {
      zramSwap = {
        enable = lib.mkDefault cfg.memory.zram.enable;
        inherit (cfg.memory.zram) memoryPercent;
      };

      boot.kernel.sysctl = {
        "vm.page-cluster" = cfg.memory.pageCluster;
        "vm.swappiness" = cfg.memory.swappiness;
        "vm.watermark_boost_factor" = cfg.memory.watermarkBoostFactor;
        "vm.watermark_scale_factor" = cfg.memory.watermarkScaleFactor;
      };
    }

    # zfs is a loadable module, so the `zfs.zfs_arc_max=` kernel-cmdline form
    # is not a reliable delivery path. extraModprobeConfig is `types.lines`,
    # so this merges with anything else writing modprobe options.
    (mkIf (cfg.memory.arcMaxBytes != null) {
      boot.extraModprobeConfig = "options zfs zfs_arc_max=${toString cfg.memory.arcMaxBytes}\n";
    })

    # ── Storage ────────────────────────────────────────────────────────────
    (mkIf (cfg.storage.manageZfs && hasZfs) (mkMerge [
      {
        services.zfs = {
          autoScrub = {
            enable = lib.mkDefault true;
            interval = lib.mkDefault cfg.storage.scrubInterval;
          };
          trim.enable = lib.mkDefault true;
        };
      }
      (mkIf cfg.storage.disableFstrim {
        services.fstrim.enable = lib.mkDefault false;
      })
    ]))

    # ── Hardening tier selection ───────────────────────────────────────────
    (mkIf cfg.hardeningTier.apply {
      hardening = {
        basic = lib.mkDefault cfg.hardeningTier.basic;
        medium = lib.mkDefault cfg.hardeningTier.medium;
      };
    })

    (mkIf cfg.hardeningTier.unlockKernelModules {
      security.lockKernelModules = lib.mkOverride 900 false;
    })
  ]);
}
