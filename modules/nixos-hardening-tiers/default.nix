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
        blacklistedKernelModules = [ "act_pedit" ];
        extraModprobeConfig = "install act_pedit ${pkgs.coreutils}/bin/true\n";

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

    (mkIf cfg.basic {
      boot = {
        kernel.sysctl = {
          "net.core.bpf_jit_enable" = lib.mkDefault false;
          "kernel.sysrq" = lib.mkForce 0;

          "net.core.rmem_max" = lib.mkDefault 16777216;
          "net.core.wmem_max" = lib.mkDefault 16777216;
          "vm.min_free_kbytes" = lib.mkDefault 65536;

          "vm.swappiness" = lib.mkDefault 2;
          "vm.vfs_cache_pressure" = 30;
          "kernel.core_pattern" = "/var/crash/core.%u.%e.%p";

          "net.ipv4.conf.all.accept_redirects" = lib.mkDefault 0;
          "net.ipv4.conf.default.accept_redirects" = lib.mkDefault 0;
          "net.ipv6.conf.all.accept_redirects" = lib.mkDefault 0;
          "net.ipv6.conf.default.accept_redirects" = lib.mkDefault 0;
          "net.ipv4.conf.all.send_redirects" = lib.mkDefault 0;
          "net.ipv4.conf.default.send_redirects" = lib.mkDefault 0;
          "net.ipv4.conf.all.accept_source_route" = lib.mkDefault 0;
          "net.ipv4.conf.default.accept_source_route" = lib.mkDefault 0;
          "net.ipv4.conf.all.log_martians" = lib.mkDefault 1;
          "fs.protected_fifos" = lib.mkDefault 2;
          "fs.protected_regular" = lib.mkDefault 2;
        };
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

    (mkIf cfg.medium {
      security = {
        protectKernelImage = lib.mkDefault true;
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

    (mkIf cfg.advanced {
      security = {
        allowSimultaneousMultithreading = lib.mkDefault false;
        forcePageTableIsolation = lib.mkDefault true;
        virtualisation.flushL1DataCache = lib.mkDefault "always";
        apparmor.enable = lib.mkDefault true;
        apparmor.killUnconfinedConfinables = lib.mkDefault true;
      };
      boot = {
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
