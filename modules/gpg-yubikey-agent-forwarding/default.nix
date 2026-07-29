# gpg-yubikey-agent-forwarding
#
# A NixOS module that configures a hardened GnuPG agent (tuned for a YubiKey /
# smartcard) and, crucially, makes a host able to *receive* a gpg-agent that is
# forwarded to it over SSH.
#
# The forwarding trap this solves:
#   When another machine forwards its gpg-agent socket with SSH's
#   `RemoteForward`, sshd binds the socket path on this host *before* your login
#   shell would normally create `/run/user/<uid>/gnupg`. If that directory does
#   not already exist (or exists with loose permissions), the forward fails —
#   and it fails *silently*. This module pre-creates the directory with mode
#   0700 via a oneshot user service, and forces the host's own gpg-agent off so
#   it can't shadow the tunneled socket.
#
# Drop this file in as a module (e.g. `imports = [ ./gpg-yubikey-agent-forwarding ];`)
# and set `modules.gpg.enable = true;`.
{
  pkgs,
  config,
  options,
  lib,
  ...
}:
let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optionalAttrs types;
  cfg = config.modules.gpg;
  runDir = "/run/user/${toString cfg.uid}/gnupg";
in
{
  options.modules.gpg = {
    enable = mkEnableOption "hardened GnuPG + YubiKey agent support";

    user = mkOption {
      type = types.str;
      default = "youruser";
      example = "alice";
      description = "Login user whose Home Manager gpg config is written (when configureHomeManager is set).";
    };

    uid = mkOption {
      type = types.int;
      default = 1000;
      description = ''
        Numeric uid of `user`. Used to build the runtime socket paths
        (`/run/user/<uid>/gnupg/...`). Must match the receiving user's real uid,
        otherwise the forwarded socket lands in a directory nothing reads.
      '';
    };

    enableAgent = mkOption {
      type = types.bool;
      default = true;
      description = "Run a local gpg-agent (forced off on hosts that receive a forwarded agent).";
    };

    enableSSHSupport = mkOption {
      type = types.bool;
      default = true;
      description = "Use the GPG agent as the SSH agent (forced off on hosts that receive a forwarded agent).";
    };

    receiveForwardedAgent = mkOption {
      type = types.bool;
      default = false;
      description = ''
        This host receives a gpg-agent forwarded over SSH. Disables the local
        agent and its SSH support (so they can't shadow the tunnel) and enables
        the oneshot service that pre-creates the runtime gnupg directory.
      '';
    };

    pinentryPackage = mkOption {
      type = types.package;
      default = pkgs.pinentry-curses;
      example = lib.literalExpression "pkgs.pinentry-qt";
      description = ''
        pinentry program the agent uses to prompt for the PIN. Use a graphical
        pinentry (e.g. pinentry-qt / pinentry-gnome3) on desktops and
        pinentry-curses on headless hosts.
      '';
    };

    keyId = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0x0000000000000000";
      description = ''
        Optional GPG key id exported as the `KEYID` session variable for
        convenience in scripts. Left unset by default.
      '';
    };

    publicKeys = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      example = lib.literalExpression ''
        [ { source = ./keys/yubikey.asc; trust = 5; } ]
      '';
      description = ''
        Public keys to import + trust via Home Manager's `programs.gpg.publicKeys`.
        Point `source` at your own exported `.asc` file. Only applied when
        `configureHomeManager` is true and a local agent runs.
      '';
    };

    configureHomeManager = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also write a hardened `programs.gpg` config for `user` via Home Manager.
        Requires the Home Manager NixOS module to be imported. Leave off if you
        manage gpg.conf yourself.
      '';
    };

    forwardRemoteOption = mkOption {
      type = types.str;
      readOnly = true;
      default = "${runDir}/S.gpg-agent ${runDir}/S.gpg-agent.extra";
      description = ''
        Read-only. The exact `RemoteForward` value (remote-socket local-socket)
        the *sending* host must use to tunnel its agent to this host. Read-only
        so this string stays in lockstep with the consuming SSH config — read it
        from here instead of hand-copying the socket pair.

        On the sender, roughly:
          programs.ssh.extraConfig = '''
            Host your-host
              RemoteForward ''${nodes.your-host.config.modules.gpg.forwardRemoteOption}
          ''';
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # A host receiving a forwarded agent must not run its own — a local agent
      # would shadow the tunneled socket.
      modules.gpg.enableAgent = mkIf cfg.receiveForwardedAgent false;
      modules.gpg.enableSSHSupport = mkIf cfg.receiveForwardedAgent false;

      # Pre-create /run/user/<uid>/gnupg with mode 0700 BEFORE any SSH
      # RemoteForward tries to bind a socket inside it. Without this the forward
      # fails silently: sshd binds the path before login creates the directory,
      # and a missing / loose-perm dir kills the forward with no visible error.
      systemd.user.services.gpg-forward-dir = mkIf cfg.receiveForwardedAgent {
        description = "Pre-create GPG agent forwarding directory";
        wantedBy = [ "default.target" ];
        serviceConfig = {
          Type = "oneshot";
          # %t expands to the user's XDG_RUNTIME_DIR (/run/user/<uid>).
          ExecStart = "${pkgs.coreutils}/bin/mkdir -p %t/gnupg";
          ExecStartPost = "${pkgs.coreutils}/bin/chmod 700 %t/gnupg";
          RemainAfterExit = true;
        };
      };

      environment.sessionVariables = mkIf (cfg.keyId != null) {
        KEYID = cfg.keyId;
      };

      programs.gnupg.agent = mkIf cfg.enableAgent {
        enable = true;
        enableSSHSupport = cfg.enableSSHSupport;
        enableExtraSocket = true;
        settings = {
          default-cache-ttl = 60;
          max-cache-ttl = 120;
        };
        pinentryPackage = cfg.pinentryPackage;
      };
    }

    # Home Manager gpg config, written to `home-manager.users.<user>`.
    #
    # Two-level gate, and the ordering of the two conditions matters:
    #
    #   * The outer `optionalAttrs (options ? home-manager)` decides whether the
    #     `home-manager` attribute *name* appears in config at all. It must be
    #     keyed on `options` (which modules are imported) — a value that does
    #     NOT depend on config — because the module system has to know every
    #     definition's attribute names before it can evaluate any option value.
    #     Keying this on a config value (e.g. `cfg.configureHomeManager`) would
    #     infinite-recurse; keying it on a bare `mkIf` would instead abort with
    #     "The option `home-manager' does not exist" on hosts without Home
    #     Manager, because the option-existence check ignores the mkIf condition.
    #     `options ? home-manager` is static, so it is safe: the attribute simply
    #     vanishes when the Home Manager NixOS module is not imported, and the
    #     base agent/forwarding config keeps working standalone.
    #
    #   * The inner `mkIf cfg.configureHomeManager` gates the actual value — safe
    #     to key on a config value here, since the attribute name is already
    #     present (Home Manager declares it) whenever this branch is reachable.
    (optionalAttrs (options ? home-manager) {
      home-manager.users.${cfg.user} = mkIf cfg.configureHomeManager {
        programs.gpg = {
          enable = true;
          publicKeys = mkIf cfg.enableAgent cfg.publicKeys;
          settings = {
            personal-cipher-preferences = "AES256 AES192 AES";
            personal-digest-preferences = "SHA512 SHA384 SHA256";
            personal-compress-preferences = "ZLIB BZIP2 ZIP Uncompressed";
            default-preference-list = "SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed";
            cert-digest-algo = "SHA512";
            s2k-digest-algo = "SHA512";
            s2k-cipher-algo = "AES256";
            charset = "utf-8";
            keyid-format = "0xlong";
            list-options = "show-uid-validity";
            verify-options = "show-uid-validity";
            throw-keyids = true;
            no-comments = true;
            no-emit-version = true;
            no-greeting = true;
            with-fingerprint = true;
            require-cross-certification = true;
            no-symkey-cache = true;
            armor = true;
            use-agent = true;
          };
          # disable-ccid works around flaky CCID drivers for many YubiKeys;
          # gpg then talks to the card via its internal PC/SC path.
          scdaemonSettings = {
            disable-ccid = true;
          };
        };
      };
    })
  ]);
}
