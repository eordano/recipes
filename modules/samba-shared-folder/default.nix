{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.shared-folder;
in
{
  options.modules.services.shared-folder = {
    enable = mkEnableOption "SMB shared folder";

    sharePath = mkOption {
      type = types.str;
      default = "/srv/shared";
      description = "Path to the shared folder on disk.";
    };

    shareName = mkOption {
      type = types.str;
      default = "shared";
      description = "Name of the SMB share as seen by clients (\\\\host\\<shareName>).";
    };

    group = mkOption {
      type = types.str;
      default = "shared";
      description = "POSIX group that owns the shared folder. Files are force-grouped to it so all share members can read each other's writes.";
    };

    workgroup = mkOption {
      type = types.str;
      default = "WORKGROUP";
      description = "SMB workgroup name.";
    };

    interfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Interfaces/subnets to bind Samba to. Empty = all interfaces. When set, 'bind interfaces only' is enabled.";
      example = [
        "192.168.1.0/24"
        "10.0.0.0/24"
      ];
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to open the SMB firewall ports (445/139). Off by default: the
        share is unreachable off-box until you open the firewall.

        NOTE: this uses NixOS's `services.samba.openFirewall`, which opens the
        ports on ALL interfaces -- it is NOT scoped by the `interfaces` option
        above (that only controls which addresses smbd binds to). On a
        multi-homed or public-facing host, prefer leaving this `false` and
        adding your own interface-scoped firewall rules
        (`networking.firewall.interfaces.<iface>.allowedTCPPorts = [ 445 139 ]`).
      '';
    };

    smbUsers = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            passwordFile = mkOption {
              type = types.path;
              description = "Path to a file whose contents are this user's SMB password. Keep it out of the Nix store (e.g. an agenix/sops secret or a /run path).";
            };
          };
        }
      );
      default = { };
      description = ''
        SMB users and their password-file paths.

        IMPORTANT: each name here must ALSO be an existing system user
        (users.users.<name>). This module creates only the group, not the
        accounts. A name with no matching system user is silently skipped and
        surfaces later as an auth failure, never a build error.
      '';
      example = literalExpression ''
        {
          alice.passwordFile = "/run/secrets/alice-smb";
          bob.passwordFile = "/run/secrets/bob-smb";
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.smbUsers != { };
        message = "modules.services.shared-folder: at least one smbUser must be configured";
      }
    ];

    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.sharePath} 0770 root ${cfg.group} - -"
    ];

    services.samba = {
      enable = true;
      inherit (cfg) openFirewall;
      nmbd.enable = false;
      settings = {
        global = {
          inherit (cfg) workgroup;
          security = "user";
          "map to guest" = "Bad User";
          "server string" = "${config.networking.hostName} Shared Folder";
        }
        // optionalAttrs (cfg.interfaces != [ ]) {
          interfaces = concatStringsSep " " cfg.interfaces;
          "bind interfaces only" = "yes";
        };
        ${cfg.shareName} = {
          path = cfg.sharePath;
          browsable = "yes";
          writable = "yes";
          "guest ok" = "no";
          "valid users" = concatStringsSep "," (attrNames cfg.smbUsers);
          "force group" = cfg.group;
          "create mask" = "0660";
          "directory mask" = "0770";
        };
      };
    };

    systemd.services.setup-smb-passwords = mkIf (cfg.smbUsers != { }) {
      description = "Set up Samba passwords from secret files";
      after = [ "samba-smbd.service" ];
      wants = [ "samba-smbd.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.services.samba.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = concatStringsSep "\n" (
        mapAttrsToList (user: userCfg: ''
          if id ${escapeShellArg user} &>/dev/null; then
            if ! pdbedit -L -u ${escapeShellArg user} &>/dev/null; then
              password=$(cat ${escapeShellArg (toString userCfg.passwordFile)})
              printf '%s\n%s\n' "$password" "$password" | smbpasswd -a -s ${escapeShellArg user}
              echo "Added Samba user: ${user}"
            fi
          else
            echo "User ${user} does not exist, skipping"
          fi
        '') cfg.smbUsers
      );
    };
  };
}
