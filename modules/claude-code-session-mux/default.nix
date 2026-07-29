{
  config,
  lib,
  ...
}:
let
  cfg = config.modules.services.claude-code-mux;
  inherit (lib)
    types
    mkOption
    mkEnableOption
    mkIf
    ;
in
{
  options.modules.services.claude-code-mux = {
    enable =
      mkEnableOption "claude-code-mux: registry + WebSSH multiplexer for Claude Code sessions";

    package = mkOption {
      type = types.package;
      description = ''
        The claude-code-mux server package. This module deliberately does not
        vendor the daemon binary — supply your own `buildGoModule` derivation
        that produces `bin/claude-code-mux` accepting the flags used in the
        ExecStart below (`-addr`, `-data-dir`, `-token-file`, `-ssh-key`,
        `-known-hosts`).
      '';
      example = lib.literalExpression "pkgs.claude-code-mux";
    };

    addr = mkOption {
      type = types.str;
      default = "127.0.0.1:17800";
      description = ''
        Listen address. Bind loopback and reverse-proxy through nginx (or any
        TLS terminator). The bearer token is the ONLY thing gating registration
        writes, and the read endpoints are unauthenticated — never expose this
        address directly to the network.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/claude-code-mux";
      description = "Directory for the sessions snapshot file.";
    };

    tokenFile = mkOption {
      type = types.path;
      description = ''
        Path to the bearer token used by the registration client on every host
        that registers a session. Deliver this out of band (a secrets manager,
        systemd credential, etc.) — do not commit it.
      '';
      example = "/run/secrets/claude-code-mux-token";
    };

    user = mkOption {
      type = types.str;
      default = "claude-code-mux";
      description = "System user the daemon runs as. Owns dataDir and reads tokenFile and sshKeyPath.";
    };

    group = mkOption {
      type = types.str;
      default = "claude-code-mux";
      description = "System group for the daemon user.";
    };

    sshKeyPath = mkOption {
      type = types.path;
      description = ''
        Private SSH key the WebSSH bridge dials registered hosts with. Its
        public half must be authorized on every host that registers a session.
      '';
      example = "/var/lib/claude-code-mux/id_ed25519";
    };

    knownHostsPath = mkOption {
      type = types.path;
      description = ''
        known_hosts file used to verify the host keys of registered hosts.

        THIS IS THE SECURITY BOUNDARY. The bridge auto-routes an operator's
        terminal to a host named in caller-supplied JSON, so it refuses to dial
        any host whose key is not in this file (no trust-on-first-use). Keep it
        in sync with the host keys of every machine you intend to bridge to, or
        new hosts silently fail to open a terminal.
      '';
      example = "/var/lib/claude-code-mux/known_hosts";
    };
  };

  config = mkIf cfg.enable {
    users.groups.${cfg.group} = mkIf (cfg.group == "claude-code-mux") { };
    users.users.${cfg.user} = mkIf (cfg.user == "claude-code-mux") {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = false;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.claude-code-mux = {
      description = "Claude Code session registry + WebSSH bridge";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart =
          "${cfg.package}/bin/claude-code-mux"
          + " -addr ${cfg.addr}"
          + " -data-dir ${cfg.dataDir}"
          + " -token-file ${cfg.tokenFile}"
          + " -ssh-key ${cfg.sshKeyPath}"
          + " -known-hosts ${cfg.knownHostsPath}";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "claude-code-mux";
        StateDirectoryMode = "0700";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
    };
  };
}
