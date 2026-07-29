# remote-luks-unlock
#
# A NixOS module that makes a locked LUKS root remotely unlockable over SSH
# during the initrd boot stage. When the machine boots, it stops at the
# passphrase prompt with no console attached; this module brings up networking
# and an SSH server *inside the initrd* so an operator can connect and type the
# passphrase, after which the boot continues normally.
#
# The subtle parts (all preserved below):
#   * The initrd login shell runs `systemd-tty-ask-password-agent --query`
#     (NOT `--watch`) so it answers the one pending prompt and exits.
#   * You must connect with `ssh -t` (a PTY) or the agent has no tty and the
#     session closes without ever prompting.
#   * The unlock interface must be configured explicitly, or SSH binds to no
#     address and is unreachable.
# See README.md for the full explanation and the wrong-password lockout trap.
#
# Usage:
#   imports = [ ./remote-luks-unlock ];
#   modules.unlock-ssh = {
#     enable = true;
#     hostKeys = { ssh_host_ed25519_key = "/path/to/initrd_host_ed25519_key"; };
#     authorizedKeys = [ "ssh-ed25519 AAAA... operator@example.com" ];
#     networkInterface = "enp1s0";
#   };

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.unlock-ssh;

  # The initrd login shell. Answering exactly one pending password request and
  # then exiting is deliberate: `--query` handles the queued prompt and returns,
  # so the SSH session closes on accept and the boot proceeds. `--watch` would
  # instead block forever waiting for prompts that never arrive.
  askPassShell = pkgs.writeScript "initrd-unlock-askpass" ''
    #!/bin/sh
    exec ${config.boot.initrd.systemd.package}/bin/systemd-tty-ask-password-agent --query
  '';
in
{
  options.modules.unlock-ssh = {
    enable = lib.mkEnableOption "remote LUKS disk unlocking via SSH";

    hostKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      description = ''
        SSH host keys to embed in the initrd, as an attrset of
        `filename -> path-to-private-key`. These must be the PRIVATE keys and
        should be dedicated initrd host keys, distinct from the running
        system's host keys. Their fingerprints will differ from the booted
        system, so operators typically pin them under a separate
        `HostKeyAlias`/known_hosts entry.
      '';
      example = lib.literalExpression ''
        { ssh_host_ed25519_key = "/run/secrets/initrd_host_ed25519_key"; }
      '';
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "SSH public keys authorized to connect to the initrd and unlock the encrypted devices.";
      default = config.users.users.root.openssh.authorizedKeys.keys;
      defaultText = lib.literalExpression "config.users.users.root.openssh.authorizedKeys.keys";
      example = lib.literalExpression ''[ "ssh-ed25519 AAAA... operator@example.com" ]'';
    };

    networkInterface = lib.mkOption {
      type = lib.types.str;
      description = ''
        Network interface to bring up in the initrd for SSH access. This MUST
        match the real interface name in the initrd (check with `ip link` from
        a running system). Without it the interface never gets an address and
        the initrd SSH server, while listening, is unreachable.
      '';
      default = "eth0";
      example = "enp5s0";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      description = "Port the initrd SSH server listens on.";
      default = 22;
    };

    promptOnLogin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the systemd password agent automatically when an operator SSHes
        into the initrd, so they are prompted for the LUKS passphrase on
        connect (and the boot continues once it is entered) instead of having
        to run `systemd-tty-ask-password-agent --query` by hand.

        Remember to connect with `ssh -t` so the agent gets a PTY; without one
        the session closes immediately with no prompt.
      '';
    };

    static = {
      enable = lib.mkOption {
        type = lib.types.bool;
        description = "Use a static IP for the unlock interface instead of DHCP.";
        default = false;
      };

      address = lib.mkOption {
        type = lib.types.str;
        description = "Static IP address (with CIDR prefix) for the unlock interface.";
        default = "";
        example = "192.168.1.50/24";
      };

      gateway = lib.mkOption {
        type = lib.types.str;
        description = "Default gateway for the unlock interface.";
        default = "";
        example = "192.168.1.1";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "modules.unlock-ssh.authorizedKeys must not be empty";
      }
      {
        assertion = cfg.static.enable -> cfg.static.address != "" && cfg.static.gateway != "";
        message = "When modules.unlock-ssh.static networking is enabled, both address and gateway must be set";
      }
    ];

    boot.initrd = {
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = cfg.sshPort;
          hostKeys = lib.mapAttrsToList (name: _: "/etc/secrets/initrd/${name}") cfg.hostKeys;
          authorizedKeys = cfg.authorizedKeys;
        };
      };

      systemd = {
        enable = true;
        # The root login shell in the initrd is the password agent itself, so an
        # SSH connection immediately prompts for the passphrase.
        users.root.shell = lib.mkIf cfg.promptOnLogin "${askPassShell}";
        storePaths = lib.mkIf cfg.promptOnLogin [ askPassShell ];
        network = {
          enable = true;
          # Explicit interface config is mandatory: without it the initrd comes
          # up with no address and SSH is unreachable.
          networks."50-unlock" = {
            matchConfig.Name = cfg.networkInterface;
            networkConfig =
              if cfg.static.enable then
                {
                  Address = cfg.static.address;
                  Gateway = cfg.static.gateway;
                }
              else
                {
                  DHCP = "yes";
                };
          };
        };
      };

      # Copy the private host keys into the initrd's secret store so the SSH
      # server can present a stable identity across reboots.
      secrets = lib.mapAttrs' (
        name: value: lib.nameValuePair "/etc/secrets/initrd/${name}" (lib.mkForce value)
      ) cfg.hostKeys;
    };
  };
}
