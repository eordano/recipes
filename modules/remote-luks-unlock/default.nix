{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.unlock-ssh;

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
          inherit (cfg) authorizedKeys;
        };
      };

      systemd = {
        enable = true;
        users.root.shell = lib.mkIf cfg.promptOnLogin "${askPassShell}";
        storePaths = lib.mkIf cfg.promptOnLogin [ askPassShell ];
        network = {
          enable = true;
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

      secrets = lib.mapAttrs' (
        name: value: lib.nameValuePair "/etc/secrets/initrd/${name}" (lib.mkForce value)
      ) cfg.hostKeys;
    };
  };
}
