/*
  NixOS Hardening Module
  ======================

  A modular security hardening configuration with preset levels and
  individual feature toggles.

  ## Options

  | Option            | Type          | Default   | Description                          |
  |-------------------|---------------|-----------|--------------------------------------|
  | preset            | enum          | "basic"   | Hardening level: none/basic/medium/advanced |
  | scudo             | bool          | true      | Scudo hardened memory allocator      |
  | hardenedKernel    | bool          | false     | Use hardened kernel (breaks NVIDIA)  |
  | antivirus         | bool          | false     | ClamAV antivirus daemon              |
  | auditd            | bool          | false     | Security audit logging               |
  | denyModules.*     | bool          | varies    | Categorized kernel module blocking   |
  | extraDenyModules  | list          | []        | Additional kernel modules to block   |
  | features.*        | bool          | false     | Individual feature toggles           |

  ## Preset Levels

  ┌──────────────────────────────────────────────────────────────────┐
  │ basic          │ medium (+ basic)   │ advanced (+ medium)        │
  ├────────────────┼────────────────────┼────────────────────────────┤
  │ kernelHardening│ protectKernelImage │ disableSmt                 │
  │ blacklistMods  │ lockKernelModules  │ forcePageTableIsolation    │
  │ networkBuffers │ ptraceRestrict     │ flushL1Cache               │
  │ crashLogs      │ bpfHarden          │ apparmor                   │
  │                │ tcpHarden          │ initOnAlloc                │
  │                │ networkHarden      │ iommu                      │
  │                │ restrictDmesg      │ kernelLockdown             │
  └────────────────┴────────────────────┴────────────────────────────┘

  ## Usage Examples

  Simple preset:
  ```nix
  modules.harden.preset = "medium";
  ```

  Preset with customization:
  ```nix
  modules.harden = {
    preset = "medium";
    features.disableSmt = false;  # Override: keep SMT enabled
    features.apparmor = true;     # Add feature from advanced
    extraDenyModules = [ "bluetooth" "thunderbolt" ];
  };
  ```

  À la carte (no preset):
  ```nix
  modules.harden = {
    preset = "none";
    scudo = true;
    features = {
      kernelHardening = true;
      tcpHarden = true;
      networkHarden = true;
    };
  };
  ```

  ## Compatibility Notes

  | Feature              | Impact                                        |
  |----------------------|-----------------------------------------------|
  | hardenedKernel       | Breaks NVIDIA and some proprietary drivers    |
  | lockKernelModules    | Breaks USB hotplug, late module loading       |
  | disableSmt           | ~50% performance loss on threaded workloads   |
  | ptraceRestrict       | Breaks gdb/strace without sudo                |
  | apparmor             | May require profile tuning for custom apps    |
  | iommu                | Requires CPU/motherboard support              |

  ## Built-in Conflict Detection

  This module includes assertions that detect incompatible configurations:

  ### hardenedKernel conflicts with:
  - hardware.nvidia.* (proprietary drivers)
  - virtualisation.virtualbox.host (out-of-tree modules)
  - virtualisation.vmware.host (out-of-tree modules)
  - boot.zfs (potential symbol conflicts)

  ### lockKernelModules conflicts with:
  - hardware.bluetooth (dynamic module loading)
  - networking.wireguard (runtime module loading)
  - USB hotplug devices (udev-triggered loading)

  ### bpfHarden conflicts with:
  - services.bpftune (requires unprivileged BPF)
  - services.scx (eBPF-based schedulers)
  - programs.bcc (BPF compiler collection)
  - systemd RestrictNetworkInterfaces directives

  ### ptraceRestrict conflicts with:
  - programs.bandwhich (CAP_SYS_PTRACE)
  - GDB, strace, valgrind (as non-root user)
  - services.netdata (some plugins)

  ### kernelLockdown conflicts with:
  - hardware.nvidia.* (unsigned modules)
  - boot.crashDump (requires kexec)
  - programs.systemtap (kernel debugging)
  - hardware.cpu.x86.msr (MSR access)
  - services.undervolt (MSR writes)

  ### apparmor conflicts with:
  - virtualisation.docker (without profiles)
  - virtualisation.libvirtd (QEMU processes)
  - services.flatpak (user namespaces)
  - virtualisation.podman (rootless mode)

  ### scudo conflicts with:
  - JVM applications (elasticsearch, keycloak)
  - Real-time audio (jack, pipewire)
  - Some databases (redis, mongodb use jemalloc)

  ### iommu may impact:
  - hardware.infiniband (RDMA performance)
  - GPU passthrough (requires careful config)
  - Older hardware without IOMMU support

  ### disableSmt impacts:
  - services.hydra (build farm performance)
  - High-throughput services (databases, web servers)
  - Compilation workloads (~50% slower)

  ## Module Deny Categories

  Module blocking is now categorized for desktop/server flexibility:

  | Category                 | Default | Modules                                    |
  |--------------------------|---------|-------------------------------------------|
  | obscureFilesystems       | true    | adfs, affs, bfs, hfs, minix, ntfs, etc.   |
  | obscureNetworkProtocols  | true    | ax25, netrom, dccp, sctp, rds, tipc       |
  | firewire                 | true    | firewire-core, firewire-ohci, firewire-sbp2|
  | thunderbolt              | false   | thunderbolt (needed for docks/eGPUs)      |
  | bluetooth                | false   | bluetooth, btusb, btrtl, btintel, etc.    |
  | webcam                   | false   | uvcvideo                                  |
  | cdrom                    | false   | cdrom, sr_mod                             |
  | floppy                   | true    | floppy                                    |
  | framebuffer              | false   | vesafb, efifb, simplefb                   |
  | legacyInput              | true    | pcspkr, snd_pcsp, serio_raw               |

  ### Server Configuration (maximum security)
  ```nix
  modules.harden.denyModules = {
    thunderbolt = true;  # No external docks
    bluetooth = true;    # No wireless peripherals
    webcam = true;       # No video conferencing
    cdrom = true;        # No optical drives
  };
  ```

  ### Desktop Configuration (balanced)
  ```nix
  modules.harden.denyModules = {
    # Keep defaults: bluetooth, thunderbolt, webcam = false
    # These are desktop-friendly by default
  };
  ```

  ### Laptop Configuration
  ```nix
  modules.harden.denyModules = {
    # Keep bluetooth/webcam enabled
    firewire = true;     # Laptops rarely have FireWire
    cdrom = true;        # Modern laptops lack optical drives
  };
  ```

  Use `extraDenyModules` for additional modules not in categories.
*/
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
    types
    mkOption
    mkDefault
    mkForce
    mkOverride
    ;
  cfg = config.modules.harden;

  # Preset definitions
  presets = {
    basic = {
      kernelHardening = true;
      blacklistObscureModules = true;
      networkBuffers = true;
      crashLogs = true;
    };
    medium = {
      kernelHardening = true;
      blacklistObscureModules = true;
      networkBuffers = true;
      crashLogs = true;
      protectKernelImage = true;
      lockKernelModules = true;
      ptraceRestrict = true;
      bpfHarden = true;
      tcpHarden = true;
      networkHarden = true;
      restrictDmesg = true;
    };
    advanced = {
      kernelHardening = true;
      blacklistObscureModules = true;
      networkBuffers = true;
      crashLogs = true;
      protectKernelImage = true;
      lockKernelModules = true;
      ptraceRestrict = true;
      bpfHarden = true;
      tcpHarden = true;
      networkHarden = true;
      restrictDmesg = true;
      disableSmt = true;
      forcePageTableIsolation = true;
      flushL1Cache = true;
      apparmor = true;
      initOnAlloc = true;
      iommu = true;
      kernelLockdown = true;
    };
  };

  # Apply preset settings
  activePreset = presets.${cfg.preset} or { };

  # Check if a feature is enabled
  # Uses OR logic: enabled if preset has it OR feature is explicitly enabled
  # To disable a preset feature, use preset = "none" and enable features individually
  isEnabled = option: activePreset.${option} or false || cfg.features.${option} or false;
in
{
  options.modules.harden = {
    preset = mkOption {
      description = "Hardening preset level";
      type = types.enum [
        "none"
        "basic"
        "medium"
        "advanced"
      ];
      default = "basic";
    };

    scudo = mkOption {
      description = "Enable Scudo hardened malloc";
      type = types.bool;
      default = true;
    };

    hardenedKernel = mkEnableOption "hardened kernel package (may break proprietary drivers)";

    antivirus = mkEnableOption "ClamAV Antivirus";

    auditd = mkEnableOption "audit daemon for security logging";

    extraDenyModules = mkOption {
      description = "Additional kernel modules to blacklist";
      type = types.listOf types.str;
      default = [ ];
      example = [
        "vivid"
        "v4l2loopback"
      ];
    };

    denyModules = {
      obscureFilesystems = mkOption {
        description = "Block old/rare filesystems (adfs, hfs, minix, etc.)";
        type = types.bool;
        default = true;
      };
      obscureNetworkProtocols = mkOption {
        description = "Block obscure network protocols (ax25, netrom, rose, dccp, sctp, rds, tipc)";
        type = types.bool;
        default = true;
      };
      firewire = mkOption {
        description = "Block FireWire/IEEE1394 (DMA attack vector)";
        type = types.bool;
        default = true;
      };
      thunderbolt = mkOption {
        description = "Block Thunderbolt (DMA attack vector, disable for docks/eGPUs)";
        type = types.bool;
        default = false; # Desktop-friendly default
      };
      bluetooth = mkOption {
        description = "Block Bluetooth (large attack surface)";
        type = types.bool;
        default = false; # Desktop-friendly default
      };
      webcam = mkOption {
        description = "Block USB webcam (uvcvideo)";
        type = types.bool;
        default = false; # Desktop-friendly default
      };
      cdrom = mkOption {
        description = "Block CD-ROM/DVD drives";
        type = types.bool;
        default = false; # Some desktops still use optical drives
      };
      floppy = mkOption {
        description = "Block floppy disk driver";
        type = types.bool;
        default = true; # Nobody uses floppies anymore
      };
      framebuffer = mkOption {
        description = "Block legacy framebuffer drivers (not for desktops with GUI)";
        type = types.bool;
        default = false; # Needed for some boot splashes
      };
      legacyInput = mkOption {
        description = "Block legacy input (pcspkr, serio_raw)";
        type = types.bool;
        default = true;
      };
    };

    features = {
      # Kernel hardening
      kernelHardening = mkEnableOption "basic kernel sysctl hardening";
      blacklistObscureModules = mkEnableOption "blacklist obscure filesystems and protocols";
      networkBuffers = mkEnableOption "increased network buffer sizes";
      crashLogs = mkEnableOption "dedicated crash log directory";

      # Medium features
      protectKernelImage = mkEnableOption "protect kernel image from modification";
      lockKernelModules = mkEnableOption "lock kernel modules after boot (breaks USB hotplug)";
      ptraceRestrict = mkEnableOption "restrict ptrace to root only";
      bpfHarden = mkEnableOption "BPF JIT hardening";
      tcpHarden = mkEnableOption "TCP SYN flood protection";
      networkHarden = mkEnableOption "network stack hardening (redirects, source routing)";
      restrictDmesg = mkEnableOption "restrict dmesg to root";

      # Advanced features
      disableSmt = mkEnableOption "disable SMT/hyperthreading (50% performance impact)";
      forcePageTableIsolation = mkEnableOption "force page table isolation";
      flushL1Cache = mkEnableOption "flush L1 cache on VM entry";
      apparmor = mkEnableOption "AppArmor mandatory access control";
      initOnAlloc = mkEnableOption "zero memory on allocation and free";
      iommu = mkEnableOption "force IOMMU for DMA protection";
      kernelLockdown = mkEnableOption "kernel lockdown mode";
    };
  };

  config = lib.mkMerge [
    # ===========================================
    # COMPATIBILITY ASSERTIONS
    # ===========================================
    {
      assertions =
        let
          # Helper to check if a config path exists and is enabled
          hasEnabled = path: lib.attrByPath path false config;
        in
        [
          # ─────────────────────────────────────────
          # Hardened Kernel Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(cfg.hardenedKernel && hasEnabled [ "hardware" "nvidia" "modesetting" "enable" ]);
            message = ''
              modules.harden.hardenedKernel conflicts with hardware.nvidia.
              The hardened kernel blocks proprietary NVIDIA drivers.
              Either disable hardenedKernel or use nouveau driver.
            '';
          }
          {
            assertion = !(cfg.hardenedKernel && hasEnabled [ "virtualisation" "virtualbox" "host" "enable" ]);
            message = ''
              modules.harden.hardenedKernel conflicts with virtualisation.virtualbox.host.
              VirtualBox requires out-of-tree kernel modules incompatible with hardened kernel.
            '';
          }
          {
            assertion = !(cfg.hardenedKernel && hasEnabled [ "virtualisation" "vmware" "host" "enable" ]);
            message = ''
              modules.harden.hardenedKernel conflicts with virtualisation.vmware.host.
              VMware requires kernel modules incompatible with hardened kernel.
            '';
          }
          {
            assertion = !(cfg.hardenedKernel && hasEnabled [ "boot" "zfs" "enabled" ]);
            message = ''
              modules.harden.hardenedKernel may conflict with ZFS.
              ZFS kernel module has known compatibility issues with hardened kernels.
              Test thoroughly before deploying.
            '';
          }

          # ─────────────────────────────────────────
          # Lock Kernel Modules Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(isEnabled "lockKernelModules" && hasEnabled [ "hardware" "bluetooth" "enable" ]);
            message = ''
              modules.harden lockKernelModules conflicts with hardware.bluetooth.
              Bluetooth requires dynamic kernel module loading.
              Add bluetooth modules to boot.kernelModules or disable lockKernelModules.
            '';
          }
          {
            assertion = !(isEnabled "lockKernelModules" && hasEnabled [ "networking" "wireguard" "enable" ]);
            message = ''
              modules.harden lockKernelModules conflicts with networking.wireguard.
              WireGuard loads kernel modules at runtime.
              Add "wireguard" to boot.kernelModules or disable lockKernelModules.
            '';
          }
          {
            assertion = !(isEnabled "lockKernelModules" && (config.services.xserver.videoDrivers or [ ]) != [ ]);
            message = ''
              modules.harden lockKernelModules may conflict with X11 video drivers.
              Some video drivers load modules dynamically.
              Ensure all required GPU modules are in boot.kernelModules.
            '';
          }

          # ─────────────────────────────────────────
          # BPF Hardening Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(isEnabled "bpfHarden" && hasEnabled [ "services" "bpftune" "enable" ]);
            message = ''
              modules.harden bpfHarden conflicts with services.bpftune.
              bpftune requires unprivileged BPF access which bpfHarden disables.
            '';
          }
          {
            assertion = !(isEnabled "bpfHarden" && hasEnabled [ "programs" "bcc" "enable" ]);
            message = ''
              modules.harden bpfHarden conflicts with programs.bcc.
              BCC tools require BPF access which bpfHarden restricts to root only.
            '';
          }
          {
            assertion = !(isEnabled "bpfHarden" && hasEnabled [ "services" "scx" "enable" ]);
            message = ''
              modules.harden bpfHarden conflicts with services.scx.
              Sched-ext CPU schedulers are eBPF-based and require BPF access.
            '';
          }

          # ─────────────────────────────────────────
          # Ptrace Restriction Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(isEnabled "ptraceRestrict" && hasEnabled [ "programs" "bandwhich" "enable" ]);
            message = ''
              modules.harden ptraceRestrict conflicts with programs.bandwhich.
              bandwhich requires CAP_SYS_PTRACE for process monitoring.
            '';
          }

          # ─────────────────────────────────────────
          # Kernel Lockdown Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(isEnabled "kernelLockdown" && hasEnabled [ "hardware" "nvidia" "modesetting" "enable" ]);
            message = ''
              modules.harden kernelLockdown conflicts with hardware.nvidia.
              Kernel lockdown blocks loading of proprietary NVIDIA modules.
            '';
          }
          {
            assertion = !(isEnabled "kernelLockdown" && hasEnabled [ "boot" "crashDump" "enable" ]);
            message = ''
              modules.harden kernelLockdown conflicts with boot.crashDump.
              Kernel lockdown blocks kexec which crashDump depends on.
            '';
          }
          {
            assertion = !(isEnabled "kernelLockdown" && hasEnabled [ "programs" "systemtap" "enable" ]);
            message = ''
              modules.harden kernelLockdown conflicts with programs.systemtap.
              SystemTap requires kernel debugging features blocked by lockdown.
            '';
          }
          {
            assertion = !(isEnabled "kernelLockdown" && hasEnabled [ "hardware" "cpu" "x86" "msr" "enable" ]);
            message = ''
              modules.harden kernelLockdown conflicts with hardware.cpu.x86.msr.
              Kernel lockdown blocks MSR access required for CPU monitoring/tuning.
            '';
          }
          {
            assertion = !(isEnabled "kernelLockdown" && hasEnabled [ "services" "undervolt" "enable" ]);
            message = ''
              modules.harden kernelLockdown conflicts with services.undervolt.
              Undervolting requires MSR write access blocked by kernel lockdown.
            '';
          }

          # ─────────────────────────────────────────
          # AppArmor Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(isEnabled "apparmor" && hasEnabled [ "virtualisation" "docker" "enable" ] && !(hasEnabled [ "virtualisation" "docker" "rootless" "enable" ]));
            message = ''
              modules.harden apparmor with killUnconfinedConfinables may conflict with Docker.
              Docker daemon runs unconfined by default. Consider using rootless Docker
              or ensure proper AppArmor profiles are configured.
            '';
          }
          {
            assertion = !(isEnabled "apparmor" && hasEnabled [ "virtualisation" "libvirtd" "enable" ]);
            message = ''
              modules.harden apparmor with killUnconfinedConfinables may affect libvirtd.
              QEMU/KVM processes may be terminated without proper AppArmor profiles.
              Ensure libvirt AppArmor integration is properly configured.
            '';
          }

          # ─────────────────────────────────────────
          # IOMMU Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(isEnabled "iommu" && hasEnabled [ "hardware" "infiniband" "enable" ]);
            message = ''
              modules.harden iommu may significantly impact Infiniband/RDMA performance.
              RDMA bypasses IOMMU for performance; forced IOMMU adds latency.
              Consider disabling iommu for HPC workloads.
            '';
          }

          # ─────────────────────────────────────────
          # Scudo Malloc Conflicts
          # ─────────────────────────────────────────
          {
            assertion = !(cfg.scudo && hasEnabled [ "services" "elasticsearch" "enable" ]);
            message = ''
              modules.harden.scudo may conflict with Elasticsearch (JVM).
              JVM applications can have issues with Scudo's allocation patterns.
              Consider disabling scudo or test thoroughly.
            '';
          }
          {
            assertion = !(cfg.scudo && hasEnabled [ "services" "jack" "jackd" "enable" ]);
            message = ''
              modules.harden.scudo may conflict with JACK audio.
              Real-time audio requires predictable malloc latency.
              Scudo's security checks may introduce audio glitches.
            '';
          }

          # ─────────────────────────────────────────
          # SMT (Hyperthreading) Warnings
          # ─────────────────────────────────────────
          {
            assertion = !(isEnabled "disableSmt" && hasEnabled [ "services" "hydra" "enable" ]);
            message = ''
              modules.harden disableSmt will significantly impact Hydra build farm.
              Disabling SMT reduces effective parallelism by ~50%.
              Build times will increase substantially.
            '';
          }

          # ─────────────────────────────────────────
          # Unprivileged User Namespaces (implicit via apparmor/advanced)
          # ─────────────────────────────────────────
          {
            assertion = !(
              isEnabled "apparmor"
              && !config.virtualisation.containers.enable
              && (
                hasEnabled [ "services" "flatpak" "enable" ]
                || hasEnabled [ "virtualisation" "podman" "enable" ]
                || hasEnabled [ "virtualisation" "docker" "rootless" "enable" ]
                || hasEnabled [ "virtualisation" "waydroid" "enable" ]
                || hasEnabled [ "virtualisation" "incus" "enable" ]
              )
            );
            message = ''
              modules.harden apparmor restricts unprivileged user namespaces by default.
              This conflicts with: Flatpak, rootless Podman/Docker, Waydroid, Incus.
              Enable virtualisation.containers.enable to allow user namespaces,
              or disable these services.
            '';
          }
        ];

      warnings =
        let
          hasEnabled = path: lib.attrByPath path false config;
          hasNonEmpty = path: (lib.attrByPath path { } config) != { };
        in
        lib.optional (isEnabled "disableSmt" && hasEnabled [ "services" "postgresql" "enable" ])
          "[harden] disableSmt is enabled with PostgreSQL. Expect ~50% reduced query parallelism."
        ++ lib.optional (isEnabled "disableSmt" && hasEnabled [ "services" "mysql" "enable" ])
          "[harden] disableSmt is enabled with MySQL. Thread pool performance will be reduced."
        ++ lib.optional (isEnabled "lockKernelModules" && (config.boot.extraModulePackages or [ ]) != [ ])
          "[harden] lockKernelModules is enabled with extraModulePackages. Ensure all modules load at boot."
        ++ lib.optional (cfg.scudo && hasNonEmpty [ "services" "redis" "servers" ])
          "[harden] scudo may conflict with Redis (uses jemalloc). Monitor for stability issues."
        ++ lib.optional (cfg.scudo && hasEnabled [ "services" "mongodb" "enable" ])
          "[harden] scudo may conflict with MongoDB (uses jemalloc). Monitor for stability issues."
        ++ lib.optional (isEnabled "bpfHarden" && hasEnabled [ "services" "netdata" "enable" ])
          "[harden] bpfHarden may disable some Netdata eBPF plugins. network-viewer.plugin affected."
        ++ lib.optional (isEnabled "ptraceRestrict" && hasEnabled [ "services" "netdata" "enable" ])
          "[harden] ptraceRestrict may affect Netdata apps.plugin process monitoring."
        ++ lib.optional (isEnabled "iommu" && hasEnabled [ "virtualisation" "kvmgt" "enable" ])
          "[harden] iommu with KVMGT requires careful IOMMU group configuration for vGPU."
        ++ lib.optional (isEnabled "iommu" && hasEnabled [ "virtualisation" "libvirtd" "enable" ])
          "[harden] iommu enabled with libvirtd. Verify IOMMU groups for PCI passthrough."
        ++ lib.optional (isEnabled "apparmor" && hasEnabled [ "virtualisation" "lxc" "enable" ])
          "[harden] AppArmor enabled with LXC. LXC has built-in AppArmor profiles that should work."
        ++ lib.optional (isEnabled "kernelLockdown" && hasEnabled [ "programs" "bcc" "enable" ])
          "[harden] kernelLockdown may restrict some BCC functionality beyond bpfHarden."
        ++ lib.optional (cfg.hardenedKernel && hasEnabled [ "hardware" "openrazer" "enable" ])
          "[harden] hardenedKernel may conflict with openrazer out-of-tree kernel module."
        ++ lib.optional (cfg.hardenedKernel && hasEnabled [ "hardware" "xpadneo" "enable" ])
          "[harden] hardenedKernel may conflict with xpadneo out-of-tree kernel module."
        ++ lib.optional (isEnabled "disableSmt" && hasEnabled [ "services" "nginx" "enable" ])
          "[harden] disableSmt with nginx. Consider adjusting worker_processes for physical cores."
        ++ lib.optional (isEnabled "disableSmt" && (config.nix.settings.max-jobs or null) != null)
          "[harden] disableSmt affects Nix build parallelism. Builds will be ~50% slower.";
    }

    # Logrotate workaround
    {
      services.logrotate.settings.nginx.enable = mkForce false;
    }

    # Crash log directory
    (mkIf (isEnabled "crashLogs") {
      systemd.tmpfiles.rules = [ "d /var/crash 0700 root root -" ];
    })

    # Scudo hardened malloc
    (mkIf cfg.scudo {
      environment = {
        memoryAllocator.provider = mkDefault "scudo";
        variables.SCUDO_OPTIONS = mkDefault "ZeroContents=1";
      };
    })

    # Hardened kernel package
    (mkIf cfg.hardenedKernel {
      boot.kernelPackages = mkDefault pkgs.linuxPackages_hardened;
    })

    # ClamAV antivirus
    (mkIf cfg.antivirus {
      services.clamav = {
        daemon.enable = true;
        updater.enable = true;
      };
    })

    # Audit daemon
    (mkIf cfg.auditd {
      security.auditd.enable = true;
      security.audit = {
        enable = true;
        rules = [
          "-w /etc/passwd -p wa -k identity"
          "-w /etc/shadow -p wa -k identity"
          "-w /etc/sudoers -p wa -k sudoers"
          "-w /etc/ssh/sshd_config -p wa -k sshd"
        ];
      };
    })

    # Basic kernel hardening
    (mkIf (isEnabled "kernelHardening") {
      boot = {
        kernel.sysctl = {
          "kernel.kptr_restrict" = mkForce 2;
          "kernel.sysrq" = mkForce 0;
          "net.core.bpf_jit_enable" = mkDefault false;
          "vm.swappiness" = mkDefault 10;
        };
        kernelParams = [
          "page_alloc.shuffle=1"
        ];
      };
      security.protectKernelImage = mkDefault true;
    })

    # Network buffer sizes
    (mkIf (isEnabled "networkBuffers") {
      boot.kernel.sysctl = {
        "net.core.rmem_max" = mkDefault 16777216;
        "net.core.wmem_max" = mkDefault 16777216;
        "vm.min_free_kbytes" = mkDefault 65536;
      };
    })

    # Crash logs
    (mkIf (isEnabled "crashLogs") {
      boot.kernel.sysctl = {
        "kernel.core_pattern" = "/var/crash/core.%u.%e.%p";
      };
    })

    # Blacklist kernel modules by category
    (mkIf (isEnabled "blacklistObscureModules") {
      boot.blacklistedKernelModules =
        # Obscure filesystems
        lib.optionals cfg.denyModules.obscureFilesystems [
          "adfs" # Acorn disk filing system
          "affs" # Amiga filesystem
          "bfs" # BFS filesystem
          "befs" # BeOS filesystem
          "cramfs" # Compressed ROM filesystem
          "efs" # EFS filesystem
          "erofs" # Enhanced read-only filesystem
          "exofs" # OSD-based filesystem
          "freevxfs" # FreeVxFS filesystem
          "f2fs" # Flash-Friendly filesystem (keep if using SSDs with f2fs)
          "hfs" # Apple HFS
          "hpfs" # OS/2 HPFS
          "jfs" # IBM JFS
          "minix" # Minix filesystem
          "nilfs2" # NILFS2 filesystem
          "ntfs" # Windows NTFS (ntfs3 is separate)
          "omfs" # Optimized MPEG filesystem
          "qnx4" # QNX4 filesystem
          "qnx6" # QNX6 filesystem
          "sysv" # System V filesystem
          "ufs" # Unix filesystem
        ]
        # Obscure network protocols
        ++ lib.optionals cfg.denyModules.obscureNetworkProtocols [
          "ax25" # Amateur radio protocol
          "netrom" # Amateur radio protocol
          "rose" # Amateur radio protocol
          "dccp" # Datagram Congestion Control Protocol
          "sctp" # Stream Control Transmission Protocol
          "rds" # Reliable Datagram Sockets
          "tipc" # Transparent Inter-process Communication
        ]
        # FireWire (DMA attack vector)
        ++ lib.optionals cfg.denyModules.firewire [
          "firewire-core"
          "firewire-ohci"
          "firewire-sbp2"
          "firewire-net"
        ]
        # Thunderbolt (DMA attack vector)
        ++ lib.optionals cfg.denyModules.thunderbolt [
          "thunderbolt"
        ]
        # Bluetooth
        ++ lib.optionals cfg.denyModules.bluetooth [
          "bluetooth"
          "btusb"
          "btrtl"
          "btbcm"
          "btintel"
          "btmtk"
        ]
        # Webcam
        ++ lib.optionals cfg.denyModules.webcam [
          "uvcvideo"
        ]
        # CD-ROM
        ++ lib.optionals cfg.denyModules.cdrom [
          "cdrom"
          "sr_mod"
        ]
        # Floppy
        ++ lib.optionals cfg.denyModules.floppy [
          "floppy"
        ]
        # Legacy framebuffer
        ++ lib.optionals cfg.denyModules.framebuffer [
          "vesafb"
          "efifb"
          "simplefb"
        ]
        # Legacy input
        ++ lib.optionals cfg.denyModules.legacyInput [
          "pcspkr"
          "snd_pcsp"
          "serio_raw"
        ]
        # User-specified extra modules
        ++ cfg.extraDenyModules;
    })

    # Protect kernel image
    (mkIf (isEnabled "protectKernelImage") {
      security.protectKernelImage = mkDefault true;
    })

    # Lock kernel modules
    (mkIf (isEnabled "lockKernelModules") {
      security.lockKernelModules = mkDefault true;
    })

    # Ptrace restrictions
    (mkIf (isEnabled "ptraceRestrict") {
      boot.kernel.sysctl = {
        "kernel.yama.ptrace_scope" = mkForce 2;
      };
    })

    # BPF hardening
    (mkIf (isEnabled "bpfHarden") {
      boot.kernel.sysctl = {
        "kernel.unprivileged_bpf_disabled" = mkOverride 500 1;
        "net.core.bpf_jit_harden" = mkForce 2;
      };
    })

    # TCP hardening
    (mkIf (isEnabled "tcpHarden") {
      boot.kernel.sysctl = {
        "net.ipv4.tcp_syncookies" = mkForce 1;
        "net.ipv4.tcp_syn_retries" = mkForce 2;
        "net.ipv4.tcp_synack_retries" = mkForce 2;
        "net.ipv4.tcp_max_syn_backlog" = mkForce 4096;
        "net.ipv4.tcp_rfc1337" = mkForce 1;
      };
    })

    # Network hardening
    (mkIf (isEnabled "networkHarden") {
      boot.kernel.sysctl = {
        "net.ipv4.conf.all.rp_filter" = mkForce 1;
        "net.ipv4.conf.default.rp_filter" = mkForce 1;
        "net.ipv4.conf.all.accept_redirects" = mkForce 0;
        "net.ipv4.conf.default.accept_redirects" = mkForce 0;
        "net.ipv6.conf.all.accept_redirects" = mkForce 0;
        "net.ipv4.conf.all.send_redirects" = mkForce 0;
        "net.ipv4.conf.all.accept_source_route" = mkForce 0;
        "net.ipv6.conf.all.accept_source_route" = mkForce 0;
        "net.ipv4.conf.all.log_martians" = mkForce 1;
        "net.ipv4.icmp_echo_ignore_broadcasts" = mkForce 1;
      };
    })

    # Restrict dmesg
    (mkIf (isEnabled "restrictDmesg") {
      boot.kernel.sysctl = {
        "kernel.dmesg_restrict" = mkForce 1;
        "fs.suid_dumpable" = mkOverride 500 0;
        "vm.unprivileged_userfaultfd" = mkForce 0;
      };
      boot.consoleLogLevel = mkOverride 500 3;
    })

    # ASLR (always enabled at medium+)
    (mkIf (isEnabled "ptraceRestrict") {
      boot = {
        kernel.sysctl = {
          "kernel.randomize_va_space" = mkForce 2;
          "kernel.ftrace_enabled" = mkDefault false;
        };
        kernelParams = [ "randomize_kstack_offset=on" ];
      };
    })

    # Disable SMT
    (mkIf (isEnabled "disableSmt") {
      security.allowSimultaneousMultithreading = mkDefault false;
    })

    # Page table isolation
    (mkIf (isEnabled "forcePageTableIsolation") {
      security.forcePageTableIsolation = mkDefault true;
    })

    # L1 cache flush
    (mkIf (isEnabled "flushL1Cache") {
      security.virtualisation.flushL1DataCache = mkDefault "always";
    })

    # AppArmor
    (mkIf (isEnabled "apparmor") {
      security.apparmor = {
        enable = mkDefault true;
        killUnconfinedConfinables = mkDefault true;
      };
    })

    # Init on alloc/free
    (mkIf (isEnabled "initOnAlloc") {
      boot.kernelParams = [
        "init_on_alloc=1"
        "init_on_free=1"
        "slab_nomerge"
      ];
    })

    # IOMMU
    (mkIf (isEnabled "iommu") {
      boot.kernelParams = [
        "iommu=force"
        "intel_iommu=on"
        "amd_iommu=force_isolation"
        "efi=disable_early_pci_dma"
      ];
    })

    # Kernel lockdown
    (mkIf (isEnabled "kernelLockdown") {
      boot.kernelParams = [
        "lockdown=confidentiality"
        "vsyscall=none"
        "debugfs=off"
      ];
    })

    # Rootless containers compatibility
    (mkIf (isEnabled "apparmor") {
      security.unprivilegedUsernsClone = config.virtualisation.containers.enable;
    })
  ];
}
