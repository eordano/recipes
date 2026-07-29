# per-uid-egress-lockdown
#
# Run an untrusted program as its own uid, inside bubblewrap, with NO network
# except a loopback CONNECT proxy that enforces a domain allowlist.
#
# The allowlist is enforced TWICE and the second one is the real one:
#
#   1. squid `http_access allow CONNECT <allowlist>` — a policy the program
#      only obeys while it honours HTTPS_PROXY. Advisory.
#   2. an nftables `output` chain that drops EVERY packet owned by the sandbox
#      uid except loopback traffic to the proxy port. Kernel-enforced; a
#      program that ignores the proxy env vars gets ENETUNREACH, not the
#      internet.
#
# Corollary, and the single easiest way to silently undo all of this: the proxy
# MUST run as a DIFFERENT uid. Same uid => the proxy's own outbound packets are
# matched by the sandbox's drop rule (proxy dies), and every rule you add to fix
# that reopens the internet for the sandboxed program. The module asserts this.
#
# See README.md for the full trap list.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.perUidEgressLockdown;

  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optionals
    optionalString
    concatStringsSep
    concatMapStringsSep
    mapAttrsToList
    escapeShellArg
    ;

  name = cfg.name;
  tableName = "${name}-egress";
  aclName = "${name}_allowed";
  proxyRuntimeDir = "${name}-squid";
  proxyRunPath = "/run/${proxyRuntimeDir}";

  # ---------------------------------------------------------------- proxy ---
  # Deny-by-default. Only CONNECT, only to SSL_ports, only to allowlisted
  # domains. `cache deny all` keeps squid from retaining anything on disk.
  squidConf = pkgs.writeText "${name}-squid.conf" (
    ''
      http_port ${cfg.proxy.listenAddress}:${toString cfg.proxy.port}
      acl ${aclName} dstdomain ${concatStringsSep " " cfg.allowedDomains}
      acl SSL_ports port ${concatMapStringsSep " " toString cfg.proxy.sslPorts}
      acl CONNECT method CONNECT
      http_access deny CONNECT !SSL_ports
      http_access allow CONNECT ${aclName}
      http_access deny all
      cache deny all
      access_log ${cfg.proxy.accessLog}
      cache_log ${cfg.proxy.cacheLog}
      pid_filename ${proxyRunPath}/squid.pid
      shutdown_lifetime ${cfg.proxy.shutdownLifetime}
    ''
    + optionalString (cfg.proxy.extraConfig != "") (cfg.proxy.extraConfig + "\n")
  );

  # ------------------------------------------------------------- lockdown ---
  # `policy accept` with explicit per-uid drops: this table only ever narrows
  # the two uids it names and never touches anybody else's traffic.
  #
  # `meta skuid` is the KERNEL uid that owns the socket. A process that made
  # itself "root" inside a user namespace is still the sandbox uid here.
  ruleLines =
    [
      ''meta skuid ${toString cfg.uid} oifname "lo" ct state established,related accept''
      ''meta skuid ${toString cfg.uid} oifname "lo" tcp dport ${toString cfg.proxy.port} accept''
    ]
    ++ map (p: ''meta skuid ${toString cfg.uid} oifname "lo" tcp dport ${toString p} accept'') cfg.extraLoopbackPorts
    ++ [
      "meta skuid ${toString cfg.uid} drop"
      ""
      "meta skuid ${toString cfg.proxyUid} ct state established,related accept"
    ]
    ++ optionals cfg.proxy.allowDns [
      "meta skuid ${toString cfg.proxyUid} udp dport 53 accept"
      "meta skuid ${toString cfg.proxyUid} tcp dport 53 accept"
    ]
    ++ map (p: "meta skuid ${toString cfg.proxyUid} tcp dport ${toString p} accept") cfg.proxy.egressPorts
    ++ [
      ''meta skuid ${toString cfg.proxyUid} oifname "lo" accept''
      "meta skuid ${toString cfg.proxyUid} drop"
    ];

  ruleBody = concatStringsSep "\n" (map (l: if l == "" then "" else "    " + l) ruleLines);

  # Written as `table` / `delete table` / `table { … }` so a re-run replaces the
  # table atomically. The bare `table inet <name>` first line exists only so the
  # `delete` cannot fail on a fresh boot where the table does not exist yet.
  egressRules = pkgs.writeText "${name}-egress.nft" ''
    table inet ${tableName}
    delete table inet ${tableName}
    table inet ${tableName} {
      chain output {
        type filter hook output priority 0; policy accept;

    ${ruleBody}
      }
    }
  '';

  # ------------------------------------------------------------- launcher ---
  sandboxPath = lib.makeBinPath cfg.launcher.packages;

  bindArg = flag: host: dest: "${flag} ${host} ${dest}";

  roMountArgs = mapAttrsToList (dest: host: bindArg "--ro-bind" (escapeShellArg host) dest) cfg.launcher.roMounts;

  stateMountArgs = mapAttrsToList (
    dest: sub:
    bindArg "--bind" (if (sub == "." || sub == "") then ''"$STATE"'' else ''"$STATE"/${sub}'') dest
  ) cfg.launcher.stateMounts;

  envArgs = mapAttrsToList (k: v: "--setenv ${k} ${escapeShellArg v}") cfg.launcher.environment;

  secretEnvArgs = mapAttrsToList (
    k: file: ''--setenv ${k} "$(cat ${escapeShellArg file})"''
  ) cfg.launcher.secretEnvironment;

  secretFileArgs = mapAttrsToList (
    dest: file: "--ro-bind ${escapeShellArg file} ${dest}"
  ) cfg.launcher.secretFiles;

  # Readability of every secret is checked at RUNTIME, not at eval. A missing
  # secret must fail this one wrapper, never the whole host's evaluation.
  secretChecks = mapAttrsToList (
    _: file: ''[ -r ${escapeShellArg file} ] || { echo "missing or unreadable secret: ${file}" >&2; exit 1; }''
  ) (cfg.launcher.secretEnvironment // cfg.launcher.secretFiles);

  stageBindArgs = optionalString cfg.mountStage.enable ''
    for d in "$STAGE"/*/; do
      [ -d "$d" ] || continue
      stage_binds+=(--ro-bind "$d" "${cfg.launcher.stageMountPoint}/$(basename "$d")")
    done
  '';

  # Assembled as a LIST and joined, never as a here-doc with interpolated
  # optional lines. An optional line that expands to "" leaves a whitespace-only
  # line with no trailing backslash, which ENDS the `exec bwrap` command: the
  # next `--…` line then becomes a command name. With the default
  # `sourceDir = null` + `mountStage.enable = false` that happened twice.
  bwrapArgs =
    [
      "--unshare-all --share-net"
      "--die-with-parent --new-session"
      "--clearenv"
      "--setenv PATH ${escapeShellArg sandboxPath}"
      "--setenv HOME ${cfg.launcher.homeMountPoint}"
      ''--setenv HTTPS_PROXY "$PROXY"''
      ''--setenv HTTP_PROXY "$PROXY"''
      ''--setenv NO_PROXY ""''
    ]
    ++ envArgs
    ++ secretEnvArgs
    ++ [
      "--proc /proc --dev /dev --tmpfs /tmp"
      "--ro-bind /nix/store /nix/store"
      "--ro-bind /etc/ssl /etc/ssl"
      "--ro-bind /etc/resolv.conf /etc/resolv.conf"
    ]
    ++ roMountArgs
    ++ secretFileArgs
    ++ optionals (cfg.sourceDir != null) [
      ''--ro-bind "$SRC" ${cfg.launcher.sourceMountPoint}''
    ]
    ++ stateMountArgs
    ++ optionals cfg.mountStage.enable [ ''"''${stage_binds[@]}"'' ]
    ++ [
      "--chdir ${cfg.launcher.workingDirectory}"
      "-- ${pkgs.bash}/bin/bash -c ${escapeShellArg cfg.launcher.command}"
    ];

  defaultLauncher = pkgs.writeShellApplication {
    name = cfg.launcher.binName;
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.coreutils
    ];
    excludeShellChecks = [ "SC2016" ];
    text = ''
      set -euo pipefail

      STATE=${escapeShellArg cfg.stateDir}
      ${optionalString (cfg.sourceDir != null) "SRC=${escapeShellArg cfg.sourceDir}"}
      ${optionalString cfg.mountStage.enable "STAGE=${escapeShellArg cfg.mountStage.dir}"}
      PROXY="http://${cfg.proxy.listenAddress}:${toString cfg.proxy.port}"

      ${optionalString (
        cfg.sourceDir != null
      ) ''[ -d "$SRC" ] || { echo "source tree not found at $SRC" >&2; exit 1; }''}
      ${optionalString cfg.mountStage.enable ''
        [ -d "$STAGE" ] || { echo "mount stage $STAGE is not present (${cfg.mountStage.unitName})" >&2; exit 1; }''}
      ${concatStringsSep "\n" secretChecks}

      ${concatMapStringsSep "\n" (d: ''mkdir -p "$STATE"/${d}'') cfg.stateSubdirs}
      ${concatMapStringsSep "\n" (f: ''[ -f "$STATE"/${f} ] || : > "$STATE"/${f}'') cfg.stateFiles}

      ${optionalString cfg.mountStage.enable "stage_binds=()"}
      ${stageBindArgs}
      exec bwrap \
        ${concatStringsSep " \\\n    " bwrapArgs}
    '';
  };

  launcherPkg = if cfg.launcher.package != null then cfg.launcher.package else defaultLauncher;

  launcherBin = "${launcherPkg}/bin/${cfg.launcher.binName}";
in
{
  options.services.perUidEgressLockdown = {
    enable = mkEnableOption "per-uid kernel egress lockdown with a co-resident allowlist proxy";

    name = mkOption {
      type = types.str;
      default = "sandbox";
      description = ''
        Prefix for everything this module names: the systemd units
        (`<name>-squid`, `<name>-egress-lockdown`), the nftables table
        (`inet <name>-egress`), the squid ACL, and `/run/<name>-squid`.
      '';
    };

    user = mkOption {
      type = types.str;
      default = cfg.name;
      defaultText = lib.literalExpression "config.services.perUidEgressLockdown.name";
      description = "Unix user the untrusted program runs as.";
    };

    uid = mkOption {
      type = types.int;
      default = 60900;
      description = ''
        STABLE uid for the sandboxed program. The nftables rules match on this
        number, so it must be pinned — an allocated (`uid = null`) system user
        can renumber and the lockdown would then be filtering a uid nobody uses.
      '';
    };

    proxyUser = mkOption {
      type = types.str;
      default = "${cfg.name}-proxy";
      defaultText = lib.literalExpression ''"''${config.services.perUidEgressLockdown.name}-proxy"'';
      description = "Unix user the allowlist proxy runs as. MUST NOT be `user`.";
    };

    proxyUid = mkOption {
      type = types.int;
      default = 60901;
      description = ''
        STABLE uid for the proxy. Must differ from `uid`: the proxy is the one
        process allowed to leave the box, and it is separated from the
        sandboxed program precisely so the sandbox's drop rule cannot be
        loosened to keep the proxy alive.
      '';
    };

    allowedDomains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        ".example.com"
        "api.example.org"
      ];
      description = ''
        squid `dstdomain` allowlist. A leading dot matches the domain and all
        of its subdomains; without it the match is exact. Empty means the
        sandbox can reach nothing at all (still a valid, if useless, config).
      '';
    };

    extraLoopbackPorts = mkOption {
      type = types.listOf types.port;
      default = [ ];
      description = ''
        Extra loopback TCP ports the sandbox uid may reach, on top of the proxy
        port. Every entry is a hole: anything listening on 127.0.0.1 of the
        HOST is reachable, because the sandbox shares the host network
        namespace. Prefer keeping this empty.
      '';
    };

    proxy = {
      package = lib.mkPackageOption pkgs "squid" { };

      listenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Loopback only. Binding this anywhere else publishes an open-ish proxy
          to the network; the lockdown table does not protect other hosts.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 3128;
        description = "Proxy port on `listenAddress`.";
      };

      sslPorts = mkOption {
        type = types.listOf types.port;
        default = [ 443 ];
        description = ''
          Ports CONNECT may target. Anything not listed is refused by
          `http_access deny CONNECT !SSL_ports` — without which the proxy is a
          general-purpose TCP tunnel to any port on an allowlisted host.
        '';
      };

      egressPorts = mkOption {
        type = types.listOf types.port;
        default = [ 443 ];
        description = ''
          TCP ports the PROXY uid may reach off-box, enforced by nftables.
          Normally the same set as `sslPorts`.
        '';
      };

      allowDns = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Let the proxy uid do DNS (53/udp + 53/tcp). The sandbox uid never
          can — all name resolution happens inside the proxy, as part of
          CONNECT.
        '';
      };

      accessLog = mkOption {
        type = types.str;
        default = "stdio:${proxyRunPath}/access.log squid";
        defaultText = lib.literalExpression ''"stdio:/run/''${name}-squid/access.log squid"'';
        description = ''
          Full squid `access_log` argument. `stdio:` avoids squid's
          `log_file_daemon` helper. The default lands in a tmpfs, so the
          request log does not persist across reboots — set
          `stdio:/dev/stdout squid` to send it to the journal instead.
        '';
      };

      cacheLog = mkOption {
        type = types.str;
        default = "${proxyRunPath}/cache.log";
        defaultText = lib.literalExpression ''"/run/''${name}-squid/cache.log"'';
        description = "squid `cache_log` path. Must be inside the runtime directory.";
      };

      shutdownLifetime = mkOption {
        type = types.str;
        default = "1 seconds";
        description = ''
          squid's `shutdown_lifetime`. The upstream default is 30 seconds and
          squid honours it on SIGTERM, so every restart of this unit stalls for
          half a minute unless it is lowered.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra squid directives, appended verbatim.";
      };
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/${cfg.name}";
      defaultText = lib.literalExpression ''"/var/lib/''${config.services.perUidEgressLockdown.name}"'';
      description = ''
        The ONLY writable place the sandboxed program has. Must not contain the
        program's own source tree — see `sourceDir`.
      '';
    };

    stateSubdirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "out"
        "tmp"
      ];
      description = "Subdirectories of `stateDir` to create (owned by `user`).";
    };

    stateFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ ".auth.json" ];
      description = ''
        Files under `stateDir` the launcher touches into existence before the
        run. bubblewrap's `--bind` of a file requires the target to already
        exist on both sides.
      '';
    };

    manageDirectories = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Emit `systemd.tmpfiles` rules for `stateDir` (+ `stateSubdirs`), the
        mount stage, and the proxy runtime directory. Turn off if the adopter
        provisions these another way (impermanence, a ZFS dataset, an existing
        tmpfiles ruleset).
      '';
    };

    sourceDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/agent-src/checkout";
      description = ''
        The sandboxed program's own code, bind-mounted READ-ONLY. Keep it
        OUTSIDE `stateDir`: if the program can write its own source tree, a
        single compromised run rewrites what the next run executes, and the
        sandbox buys you nothing but a delay.
      '';
    };

    mountStage = {
      enable = mkEnableOption "a root-owned stage of read-only bind mounts";

      dir = mkOption {
        type = types.str;
        default = "/var/lib/${cfg.name}-stage";
        defaultText = lib.literalExpression ''"/var/lib/''${config.services.perUidEgressLockdown.name}-stage"'';
        description = "Root-owned directory the read-only mirrors are mounted under.";
      };

      sources = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Host directories to bind-mount read-only into `dir`, each under its
          own basename. Staging them means the sandbox never has to traverse
          the parent directory (a home directory, a shared tree) to reach them.
        '';
      };

      unitName = mkOption {
        type = types.str;
        default = "${cfg.name}-stage";
        defaultText = lib.literalExpression ''"''${config.services.perUidEgressLockdown.name}-stage"'';
        description = "systemd unit name for the staging mounts.";
      };
    };

    launcher = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Install a wrapper that runs `command` inside bubblewrap.";
      };

      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = ''
          Escape hatch: supply your own launcher package instead of the
          generated one. It must provide `bin/<binName>`, and it is on you to
          reproduce the sandbox properties (read-only source, proxy env, no
          argument passthrough). The kernel lockdown still applies regardless,
          because it is bound to the uid, not to this wrapper.
        '';
      };

      binName = mkOption {
        type = types.str;
        default = cfg.name;
        defaultText = lib.literalExpression "config.services.perUidEgressLockdown.name";
        description = "Command name installed on PATH.";
      };

      command = mkOption {
        type = types.str;
        default = "";
        example = "exec ./run.sh";
        description = "Shell run inside the sandbox, as `bash -c`.";
      };

      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Packages whose `bin` directories make up PATH inside the sandbox.";
      };

      sourceMountPoint = mkOption {
        type = types.str;
        default = "/src";
        description = "Where `sourceDir` appears inside the sandbox (read-only).";
      };

      stageMountPoint = mkOption {
        type = types.str;
        default = "/stage";
        description = "Where the mount stage's entries appear inside the sandbox.";
      };

      homeMountPoint = mkOption {
        type = types.str;
        default = "/state";
        description = "Value of `HOME` inside the sandbox.";
      };

      workingDirectory = mkOption {
        type = types.str;
        default = "/";
        description = "`--chdir` for the sandboxed command.";
      };

      stateMounts = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          "/src/out" = "out";
          "/state" = ".";
        };
        description = ''
          Writable mounts: in-sandbox path -> path relative to `stateDir`.
          This is how a read-only source tree gets writable output
          subdirectories punched into it without making the tree writable.
        '';
      };

      roMounts = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          "/etc/hosts" = "/etc/hosts";
        };
        description = "Extra read-only mounts: in-sandbox path -> host path.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Environment inside the sandbox. The sandbox starts from `--clearenv`,
          so nothing is inherited: TLS-using programs generally need
          `SSL_CERT_FILE` (and Node additionally `NODE_EXTRA_CA_CERTS`) set to
          `/etc/ssl/certs/ca-bundle.crt`.
        '';
      };

      secretEnvironment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          API_TOKEN = "/run/secrets/api-token";
        };
        description = ''
          VAR -> file. The file is read at RUN time and passed with `--setenv`,
          so a missing secret fails this command, not the host's evaluation.
          The value transits `bwrap`'s argv; prefer `secretFiles` when the
          program can read a path.
        '';
      };

      secretFiles = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          "/run/token" = "/run/secrets/api-token";
        };
        description = "in-sandbox path -> host secret file, bind-mounted read-only.";
      };
    };

    sudo = {
      users = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Users allowed to run the launcher as `user` with NOPASSWD.";
      };

      forbidArguments = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Append `""` to the sudoers command spec, which means "this command
          with NO arguments". A bare command in sudoers permits ANY arguments,
          so without this the sudo rule is an argument-injection surface into
          whatever the launcher forwards.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.uid != cfg.proxyUid;
        message = ''
          services.perUidEgressLockdown: uid (${toString cfg.uid}) and proxyUid must differ.
          Running the proxy as the sandboxed uid means the sandbox's drop rule kills
          the proxy, and every rule that revives it hands the internet back to the
          sandboxed program.
        '';
      }
      {
        assertion = cfg.user != cfg.proxyUser;
        message = "services.perUidEgressLockdown: user and proxyUser must differ.";
      }
      {
        assertion = cfg.sourceDir == null || !(lib.hasPrefix (cfg.stateDir + "/") cfg.sourceDir);
        message = ''
          services.perUidEgressLockdown: sourceDir (${toString cfg.sourceDir}) is inside
          stateDir (${cfg.stateDir}), which the sandbox can write. Keep the code the
          sandbox runs outside everything the sandbox can modify.
        '';
      }
      {
        assertion = cfg.launcher.package == null -> !cfg.launcher.enable || cfg.launcher.command != "";
        message = "services.perUidEgressLockdown: launcher.command is empty and no launcher.package was supplied.";
      }
    ];

    warnings =
      lib.optional (config.networking.nftables.enable && config.networking.nftables.flushRuleset) ''
        services.perUidEgressLockdown: networking.nftables.flushRuleset is on. Every
        start or reload of nftables.service runs `flush ruleset`, deleting the
        inet ${tableName} table until ${name}-egress-lockdown.service next runs.
        The sandbox uid is UNFILTERED (fail-open) in that window.
      ''
      ++ lib.optional (cfg.allowedDomains == [ ]) ''
        services.perUidEgressLockdown: allowedDomains is empty; the sandbox has no
        reachable destination at all.
      '';

    users.groups.${cfg.user} = { };
    users.groups.${cfg.proxyUser} = { };

    users.users.${cfg.user} = {
      uid = cfg.uid;
      group = cfg.user;
      isSystemUser = true;
      home = cfg.stateDir;
      createHome = true;
      description = "${name} sandbox (no direct egress)";
    };

    users.users.${cfg.proxyUser} = {
      uid = cfg.proxyUid;
      group = cfg.proxyUser;
      isSystemUser = true;
      description = "${name} egress-allowlist proxy";
    };

    systemd.tmpfiles.rules = mkIf cfg.manageDirectories (
      [
        "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.user} - -"
      ]
      ++ map (d: "d ${cfg.stateDir}/${d} 0750 ${cfg.user} ${cfg.user} - -") cfg.stateSubdirs
      ++ optionals cfg.mountStage.enable [
        "d ${cfg.mountStage.dir} 0755 root root - -"
      ]
      ++ [
        "d ${proxyRunPath} 0755 ${cfg.proxyUser} ${cfg.proxyUser} - -"
      ]
    );

    # NOTE the shape: `systemd.services.<n> = mkIf false { … }` still creates
    # the ATTRIBUTE, and an attrsOf-submodule then materialises an empty unit
    # with that name. The mkIf has to sit on the attrset, not on the unit.
    systemd.services = lib.mkMerge [
      (mkIf cfg.mountStage.enable {
        ${cfg.mountStage.unitName} = {
          description = "read-only bind mounts for the ${name} sandbox stage";
          wantedBy = [ "multi-user.target" ];
          before = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = concatStringsSep "\n" (
            map (
              d:
              let
                base = baseNameOf d;
              in
              ''
                if [ -d ${escapeShellArg d} ]; then
                  mkdir -p ${cfg.mountStage.dir}/${base}
                  ${pkgs.util-linux}/bin/mountpoint -q ${cfg.mountStage.dir}/${base} \
                    || ${pkgs.util-linux}/bin/mount --bind -o ro ${escapeShellArg d} ${cfg.mountStage.dir}/${base}
                fi
              ''
            ) cfg.mountStage.sources
          );
          preStop = concatStringsSep "\n" (
            map (
              d: "${pkgs.util-linux}/bin/umount ${cfg.mountStage.dir}/${baseNameOf d} || true"
            ) cfg.mountStage.sources
          );
        };
      })
      {
        "${name}-squid" = {
          description = "${name} egress-allowlist proxy (CONNECT to allowlisted domains only)";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network.target"
            "nss-lookup.target"
          ];
          serviceConfig = {
            User = cfg.proxyUser;
            Group = cfg.proxyUser;
            RuntimeDirectory = proxyRuntimeDir;
            ExecStart = "${cfg.proxy.package}/bin/squid -f ${squidConf} -N";
            Restart = "on-failure";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            ReadWritePaths = [ proxyRunPath ];
          };
        };

        "${name}-egress-lockdown" = {
          description = "per-uid egress lockdown for the ${name} sandbox (nft table)";
          wantedBy = [ "multi-user.target" ];
          after = [ "firewall.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.nftables}/bin/nft -f ${egressRules}";
            ExecStop = "${pkgs.nftables}/bin/nft delete table inet ${tableName}";
          };
        };
      }
    ];

    environment.systemPackages = mkIf cfg.launcher.enable [ launcherPkg ];

    security.sudo.extraRules = mkIf (cfg.launcher.enable && cfg.sudo.users != [ ]) [
      {
        users = cfg.sudo.users;
        runAs = cfg.user;
        commands = [
          {
            command = launcherBin + optionalString cfg.sudo.forbidArguments " \"\"";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
