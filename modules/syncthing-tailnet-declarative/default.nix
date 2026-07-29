# syncthing-tailnet-declarative
#
# Run Syncthing as a discovery-free mesh pinned to a Tailscale (or any WireGuard)
# tailnet, and set the Web GUI password declaratively — without the password ever
# landing in the Nix store.
#
# Two ideas are bundled here:
#
#   1. A "closed mesh": global announce, relays and NAT traversal are all OFF, and
#      every peer is pinned to its fixed tailnet address. Discovery never leaves the
#      tailnet. Because those addresses only exist once the VPN is up, the daemon is
#      ordered `after` the VPN's service.
#
#   2. Declarative GUI password via the REST API. Syncthing has no Nix option for the
#      hashed GUI password, and you do not want the plaintext in the store. A oneshot
#      reads the password from a file (e.g. an agenix/sops secret) and PUTs it through
#      Syncthing's own REST API. The API key it needs is only generated on Syncthing's
#      first run, so the oneshot polls `config.xml` until the key appears.
#
# This module is provider-agnostic: point `orderAfterUnits` at whatever brings your
# tailnet up (default: tailscaled), and put your peers' pinned addresses in `devices`.

{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.syncthingTailnet;
in
{
  options.services.syncthingTailnet = {
    enable = mkEnableOption "Syncthing pinned to a tailnet with a declarative GUI password";

    user = mkOption {
      type = types.str;
      default = "syncthing";
      description = "User the Syncthing daemon runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "syncthing";
      description = "Primary group for the Syncthing user.";
    };

    uid = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Optional fixed UID for the Syncthing user. Pin this when you want the same
        numeric owner across a fleet (e.g. for shared/persisted data dirs). Leave
        null to let NixOS allocate one.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/syncthing";
      description = "Directory Syncthing stores its synced data and default folder in.";
    };

    configDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/.config/syncthing";
      defaultText = literalExpression ''"''${cfg.dataDir}/.config/syncthing"'';
      description = "Directory holding Syncthing's config.xml, keys and database.";
    };

    guiAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address the Web GUI / REST API binds to. Keep this loopback (or a tailnet
        address) — the password-setting oneshot talks to it, and the GUI has no
        password during the brief window before that oneshot runs.
      '';
    };

    guiPort = mkOption {
      type = types.port;
      default = 8384;
      description = "TCP port for the Web GUI / REST API.";
    };

    guiUser = mkOption {
      type = types.str;
      default = "syncthing";
      description = "Username set on the Web GUI alongside the password.";
    };

    guiPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/agenix/syncthing-gui-password";
      description = ''
        Path to a file containing the *plaintext* GUI password, readable by
        `user`. Wire this to your secrets manager (agenix, sops-nix, …) so the
        password never enters the Nix store. When null, no password is set and the
        GUI is left open on `guiAddress` — only acceptable on a loopback bind.
      '';
    };

    listenPort = mkOption {
      type = types.port;
      default = 22000;
      description = "TCP/UDP port Syncthing uses for peer sync traffic.";
    };

    orderAfterUnits = mkOption {
      type = types.listOf types.str;
      default = [ "tailscaled.service" ];
      example = [ "wg-quick-wg0.service" ];
      description = ''
        Units that must be up before Syncthing starts, because the pinned peer
        addresses only exist once the tailnet/VPN is established. Applied as both
        `after` and `wants` on the syncthing and syncthing-init services.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the sync port (TCP+UDP) and the local-discovery UDP port (21027) in the
        firewall. The GUI port is *not* opened — reach it over the tailnet or an SSH
        tunnel.
      '';
    };

    devices = mkOption {
      type = types.attrsOf (types.submodule { freeformType = types.attrs; });
      default = { };
      example = literalExpression ''
        {
          laptop = {
            id = "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH";
            addresses = [ "tcp://100.100.100.10:22000" ];
          };
          phone = {
            id = "IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP";
            addresses = [ "tcp://100.100.100.20:22000" ];
          };
        }
      '';
      description = ''
        Peer devices, each with its Syncthing device `id` and a list of *pinned*
        tailnet `addresses` (e.g. `tcp://<tailnet-ip>:22000`). Pinning the address
        is what keeps discovery off the public internet.
      '';
    };

    folders = mkOption {
      type = types.attrs;
      default = { };
      description = "Folders to sync, in `services.syncthing.settings.folders` form.";
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      group = cfg.group;
      isSystemUser = true;
      # When `user` is the default "syncthing", the upstream services.syncthing
      # module already pins uid = config.ids.uids.syncthing (237) at normal
      # priority, so a plain assignment here would conflict. mkForce lets an
      # explicit `uid` win over that default; null leaves upstream's uid in place.
      uid = mkIf (cfg.uid != null) (mkForce cfg.uid);
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}   0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.configDir} 0700 ${cfg.user} ${cfg.group} - -"
    ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.listenPort ];
      allowedUDPPorts = [
        cfg.listenPort
        21027 # local discovery broadcast
      ];
    };

    # The pinned peer addresses only resolve once the tailnet is up, so gate the
    # daemon (and its init helper) on whatever brings the tailnet online.
    systemd.services.syncthing = {
      after = cfg.orderAfterUnits;
      wants = cfg.orderAfterUnits;
    };
    systemd.services.syncthing-init = {
      after = cfg.orderAfterUnits;
      wants = cfg.orderAfterUnits;
    };

    # Declarative GUI password. Syncthing exposes no Nix option for the hashed
    # password and we refuse to bake plaintext into the store, so we set it through
    # the REST API. The catch: the API key is generated by Syncthing on its own
    # first run, so we must poll config.xml until it exists before we can call the API.
    systemd.services.syncthing-set-password = mkIf (cfg.guiPasswordFile != null) {
      description = "Set Syncthing GUI password from a secret file";
      requisite = [ "syncthing.service" ];
      after = [ "syncthing-init.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.curl
        pkgs.libxml2
        pkgs.jq
      ];

      script = ''
        set -efu
        umask 0077

        # Wait for Syncthing's first run to write config.xml (with the API key).
        attempts=0
        while ! xmllint \
            --xpath 'string(configuration/gui/apikey)' \
            ${escapeShellArg cfg.configDir}/config.xml \
            > "$RUNTIME_DIRECTORY/api_key" 2>/dev/null; do
          attempts=$((attempts + 1))
          if [ "$attempts" -ge 60 ]; then
            echo "Timeout waiting for Syncthing config.xml after 60s"
            exit 1
          fi
          sleep 1
        done
        API_KEY=$(cat "$RUNTIME_DIRECTORY/api_key")

        PASSWORD=$(cat ${escapeShellArg (toString cfg.guiPasswordFile)})

        # Read the current GUI config, splice in user+password, PUT it back.
        # Syncthing hashes the plaintext password on receipt.
        # Note: the GUI endpoint is loopback http by default, so no TLS occurs.
        # We do NOT pass curl -k/--insecure: it would be a latent footgun if the
        # endpoint were ever pointed at a TLS address (it would accept forged certs
        # and leak the API key + password). If you ever front this with real TLS,
        # keep verification on and trust a proper CA.
        CURRENT=$(curl -sSL \
          -H "X-API-Key: $API_KEY" \
          -H "Content-Type: application/json" \
          --retry 30 --retry-delay 1 --retry-all-errors \
          http://${cfg.guiAddress}:${toString cfg.guiPort}/rest/config/gui)

        # Keep the plaintext password out of process argv (world-readable via
        # /proc/<pid>/cmdline): pass it to jq through the environment (env.pw, from
        # /proc/<pid>/environ, mode 0400) and hand the JSON body to curl on stdin.
        UPDATED=$(echo "$CURRENT" | pw="$PASSWORD" jq \
          --arg guiuser ${escapeShellArg cfg.guiUser} \
          '.password = env.pw | .user = $guiuser')

        printf '%s' "$UPDATED" | curl -sSL \
          -H "X-API-Key: $API_KEY" \
          -H "Content-Type: application/json" \
          -X PUT --data-binary @- \
          --retry 30 --retry-delay 1 --retry-all-errors \
          http://${cfg.guiAddress}:${toString cfg.guiPort}/rest/config/gui
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "syncthing-set-password";
        User = cfg.user;
      };
    };

    services.syncthing = {
      enable = true;
      inherit (cfg) user configDir dataDir;
      group = cfg.group;
      openDefaultPorts = false;
      relay.enable = false;
      overrideDevices = true;
      overrideFolders = true;
      guiAddress = "${cfg.guiAddress}:${toString cfg.guiPort}";
      settings = {
        options = {
          urAccepted = -1; # opt out of usage reporting
          listenAddress = [ "tcp://0.0.0.0:${toString cfg.listenPort}" ];
          globalAnnounceEnabled = false; # no public discovery server
          localAnnounceEnabled = true; # LAN broadcast only
          natEnabled = false; # no UPnP/NAT-PMP
          relaysEnabled = false; # no relay servers
        };
        gui = {
          user = cfg.guiUser;
        };
        inherit (cfg) devices folders;
      };
    };
  };
}
