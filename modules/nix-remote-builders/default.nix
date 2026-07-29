{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.nix.remoteBuilders;

  thisHost = if cfg.hostName != null then cfg.hostName else config.networking.hostName;

  excluded = builtins.elem thisHost cfg.excludedHosts;

  routeNames = if excluded then [ ] else cfg.routes.${thisHost} or cfg.defaultRoute;

  # A route may name a builder that is not in the table on this evaluation —
  # tables are commonly assembled from an address book and an entry drops out
  # when its address is unknown. Filtering keeps that a degradation rather than
  # an eval error; set `strictRoutes` to turn it back into an assertion.
  unknownNames = builtins.filter (n: !(cfg.builders ? ${n})) routeNames;
  selectedNames = builtins.filter (n: cfg.builders ? ${n}) routeNames;
  selected = map (n: cfg.builders.${n}) selectedNames;

  # Several builders legitimately share one keypair. Any consumer that is
  # list-shaped rather than attrset-shaped turns the duplicate into a
  # definition conflict, so the invariant is enforced at the boundary.
  keyNames = lib.unique (map (b: b.keyName) (builtins.filter (b: b.keyName != null) selected));

  identityOf =
    b:
    if b.identityFile != null then
      b.identityFile
    else if cfg.agenix.enable && b.keyName != null then
      config.age.secrets.${b.keyName}.path
    else
      null;

  # ssh_config is FIRST-MATCH-WINS per keyword. These blocks are emitted with
  # mkBefore so they land ahead of any `Host *` that enables multiplexing —
  # see the README, that ordering is the entire defence.
  sshBlock =
    b:
    let
      identity = identityOf b;
      lines =
        [ "Host ${b.hostName}" ]
        ++ map (l: cfg.ssh.indent + l) (
          lib.optional (b.address != null) "HostName ${b.address}"
          ++ lib.optional (b.port != null) "Port ${toString b.port}"
          ++ lib.optional (b.user != null) "User ${b.user}"
          ++ lib.optional (identity != null) "IdentityFile ${identity}"
          ++ lib.optional (identity != null && cfg.ssh.identitiesOnly) "IdentitiesOnly yes"
          ++ lib.optional (
            cfg.ssh.strictHostKeyChecking != null
          ) "StrictHostKeyChecking ${cfg.ssh.strictHostKeyChecking}"
          ++ lib.optionals cfg.ssh.disableMultiplexing [
            "ControlMaster no"
            "ControlPath none"
            "ControlPersist no"
          ]
          ++ b.sshExtraLines
        );
    in
    lib.concatMapStrings (l: l + "\n") lines;

  benchTargets =
    if cfg.benchmark.targets != null then
      cfg.benchmark.targets
    else
      lib.listToAttrs (
        map (n: lib.nameValuePair n "ssh ${cfg.builders.${n}.hostName}") selectedNames
      );

  benchHostsFile = pkgs.writeText "nix-builder-bench-hosts" (
    lib.concatMapStrings (l: l + "\n") (lib.mapAttrsToList (l: c: "${l} | ${c}") benchTargets)
  );

  benchPackage = pkgs.runCommand "nix-builder-bench" {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta = {
      description = "Benchmark candidate Nix remote builders and derive a defensible speedFactor";
      mainProgram = "nix-builder-bench";
    };
  } ''
    install -Dm0755 ${./bench/nix-builder-bench.sh} $out/bin/nix-builder-bench
    patchShebangs $out/bin/nix-builder-bench
    wrapProgram $out/bin/nix-builder-bench \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.openssh
          pkgs.python3
          pkgs.coreutils
        ]
      } \
      --set-default BENCH_HOSTS_FILE ${benchHostsFile} \
      --set-default BENCH_LIST ${lib.escapeShellArg (lib.concatStringsSep " " cfg.benchmark.benchmarks)} \
      --set-default BENCH_RUNS ${toString cfg.benchmark.runs} \
      --set-default BENCH_WARMUP ${toString cfg.benchmark.warmupRuns} \
      --set-default BENCH_DISK_SIZE_MB ${toString cfg.benchmark.diskSizeMB} \
      --set-default BENCH_NIX_PKGS ${lib.escapeShellArg (lib.concatStringsSep " " cfg.benchmark.toolPackages)}
  '';

  builderModule = types.submodule (
    { name, ... }:
    {
      options = {
        hostName = mkOption {
          description = ''
            The name Nix writes into /etc/nix/machines, and the `Host` pattern
            of the generated ssh_config block. This is an ALIAS, not
            necessarily DNS: Nix documents that the hostname in `builders` may
            be an alias defined in ssh config, which is what lets one name
            carry a non-standard port, a dedicated user and a dedicated key
            without any of that appearing in /etc/nix/machines.
          '';
          type = types.str;
          default = name;
          defaultText = lib.literalExpression "the attribute name";
        };

        address = mkOption {
          description = ''
            `HostName` for the generated ssh_config block — the address the
            alias resolves to. `null` emits no HostName line, so the alias must
            itself resolve.
          '';
          type = types.nullOr types.str;
          default = null;
          example = "builder.internal.example.org";
        };

        port = mkOption {
          description = "`Port` for the generated ssh_config block.";
          type = types.nullOr types.port;
          default = 22;
        };

        user = mkOption {
          description = ''
            Remote login account. Must be able to run `nix` non-interactively
            and must be in the remote's `nix.settings.trusted-users`.
          '';
          type = types.nullOr types.str;
          default = "builder";
        };

        identityFile = mkOption {
          description = ''
            Private key path. MUST be a real filesystem path, never a store
            path — nixpkgs says so explicitly for `nix.buildMachines.*.sshKey`
            and an assertion below enforces it. Leave `null` and set `keyName`
            to have the path come from a secret manager instead.
          '';
          type = types.nullOr types.str;
          default = null;
          example = "/run/secrets/builder-key";
        };

        keyName = mkOption {
          description = ''
            Name of the secret holding this builder's private key. Only
            meaningful with `nix.remoteBuilders.agenix.enable`; several
            builders may share one name, which is exactly why the module
            de-duplicates before declaring secrets.
          '';
          type = types.nullOr types.str;
          default = null;
        };

        systems = mkOption {
          description = "Systems this builder can build for.";
          type = types.listOf types.str;
          default = [ ];
          example = [ "x86_64-linux" ];
        };

        maxJobs = mkOption {
          description = ''
            Concurrent builds Nix may schedule here. The builder enforces its
            own limits anyway; this exists so the scheduler can spread work,
            because there is no work-stealing between build machines.
          '';
          type = types.ints.positive;
          default = 1;
        };

        speedFactor = mkOption {
          description = ''
            Relative speed, higher is faster. Nix requires a POSITIVE INTEGER —
            there are no fractions, so a measured 1.7x ratio has to be rounded
            into whatever small-integer scale you keep consistent across the
            fleet. Measure it (see the bundled `nix-builder-bench`) rather than
            guessing from core counts.
          '';
          type = types.ints.positive;
          default = 1;
        };

        features = mkOption {
          description = ''
            `supportedFeatures`. A builder is skipped for any derivation whose
            `requiredSystemFeatures` it does not list, so an empty list quietly
            removes this machine from every `big-parallel` or `kvm` build.
          '';
          type = types.listOf types.str;
          default = [ ];
          example = [
            "big-parallel"
            "kvm"
          ];
        };

        mandatoryFeatures = mkOption {
          description = ''
            `mandatoryFeatures`. Inverted matching: the builder is used ONLY
            for derivations that ask for all of these. Use it to reserve a
            machine, e.g. for `benchmark` builds.
          '';
          type = types.listOf types.str;
          default = [ ];
        };

        publicHostKey = mkOption {
          description = ''
            base64 host key (`base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub`).
            `null` falls back to the regular known_hosts machinery.
          '';
          type = types.nullOr types.str;
          default = null;
        };

        protocol = mkOption {
          description = ''
            `ssh-ng` speaks the modern daemon protocol and is what you want;
            it is also the protocol that breaks the moment connection
            multiplexing is in play — read the README before turning
            `ssh.disableMultiplexing` off.
          '';
          type = types.enum [
            null
            "ssh"
            "ssh-ng"
          ];
          default = "ssh-ng";
        };

        sshExtraLines = mkOption {
          description = ''
            Extra lines appended INSIDE this builder's ssh_config block, at the
            block's indentation. Anything set here wins over a later `Host *`
            for this builder only.
          '';
          type = types.listOf types.str;
          default = [ ];
          example = [ "ProxyJump bastion" ];
        };
      };
    }
  );
in
{
  options.nix.remoteBuilders = {
    enable = mkOption {
      description = ''
        Master switch. Even when true, nothing is emitted on a host whose
        route resolves to no builders, so this module is safe to import
        unconditionally from a fleet-wide "always" list.
      '';
      type = types.bool;
      default = true;
    };

    hostName = mkOption {
      description = ''
        Key used to look this machine up in `routes` / `excludedHosts`.
        Defaults to `networking.hostName`.
      '';
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalExpression "config.networking.hostName";
    };

    builders = mkOption {
      description = ''
        The builder table: one entry per machine that MAY be used, regardless
        of who uses it. Routing is a separate decision, below.
      '';
      type = types.attrsOf builderModule;
      default = { };
    };

    routes = mkOption {
      description = ''
        Per-host ORDERED list of builder names. Order is preserved into
        /etc/nix/machines and into the generated ssh_config, so put the
        network-nearest builder first.

        Route by LOCALITY, not by "biggest box" — see the README.
      '';
      type = types.attrsOf (types.listOf types.str);
      default = { };
      example = {
        laptop-eu = [ "eu-builder" ];
        laptop-us = [
          "us-builder"
          "eu-builder"
        ];
      };
    };

    defaultRoute = mkOption {
      description = "Route for hosts with no `routes` entry of their own.";
      type = types.listOf types.str;
      default = [ ];
    };

    excludedHosts = mkOption {
      description = ''
        Hosts that must never offload: the builders themselves (a builder that
        routes to itself deadlocks its own job slots), tiny appliances whose
        uplink makes offloading slower than building, and anything whose store
        must stay self-contained.
      '';
      type = types.listOf types.str;
      default = [ ];
    };

    strictRoutes = mkOption {
      description = ''
        Fail evaluation when a route names a builder absent from the table.
        Off by default so a table assembled from a partially-known address
        book degrades instead of breaking every host at once.
      '';
      type = types.bool;
      default = false;
    };

    distributedBuilds = mkOption {
      description = "Set `nix.distributedBuilds`.";
      type = types.bool;
      default = true;
    };

    useSubstitutes = mkOption {
      description = ''
        Set `builders-use-substitutes`. Nix's own default is FALSE, which
        means the local machine uploads the full closure of every build input
        to the builder over your uplink — including paths the builder could
        fetch from cache.nixos.org at line rate. Turning it on is usually the
        single largest win in a remote-build setup.
      '';
      type = types.bool;
      default = true;
    };

    ssh = {
      manageClientConfig = mkOption {
        description = ''
          Emit the per-builder `Host` blocks into `programs.ssh.extraConfig`.
          Turn off only if you generate ssh_config some other way — and then
          you own the multiplexing problem yourself.
        '';
        type = types.bool;
        default = true;
      };

      disableMultiplexing = mkOption {
        description = ''
          Emit `ControlMaster no` / `ControlPath none` / `ControlPersist no` in
          every builder block.

          KEEP THIS ON. Funnelling many concurrent build connections onto one
          control socket breaks the `ssh-ng` daemon handshake, and a persistent
          master additionally pins a stale environment for every later session.
          See the README.
        '';
        type = types.bool;
        default = true;
      };

      identitiesOnly = mkOption {
        description = ''
          Emit `IdentitiesOnly yes` alongside `IdentityFile`. Without it ssh
          offers every key a loaded agent holds before the one you named, and
          a handful of agent keys is enough to exhaust the remote's
          `MaxAuthTries` (default 6) before the right key is ever tried.
        '';
        type = types.bool;
        default = true;
      };

      strictHostKeyChecking = mkOption {
        description = ''
          `StrictHostKeyChecking` for builder blocks. `null` emits no line.
          `accept-new` trusts first contact but still refuses a CHANGED key —
          pair it with `publicHostKey` on the builder entry if first contact
          is not trustworthy in your network.
        '';
        type = types.nullOr types.str;
        default = "accept-new";
      };

      indent = mkOption {
        description = "Indentation for keywords inside a generated `Host` block.";
        type = types.str;
        default = "  ";
      };
    };

    # These only take effect if you ALSO import ./agenix.nix, which is a
    # separate file on purpose: a module may not conditionally define an
    # option path that might not exist. `mkIf false { age.secrets = …; }` does
    # NOT hide the name — the module system pushes the mkIf down into each
    # attribute first, registers `age` as a defined path, and then fails with
    # "The option `age' does not exist" on any host without agenix. See the
    # README.
    agenix = {
      enable = mkEnableOption ''
        resolving each builder's IdentityFile from
        `config.age.secrets.<keyName>.path`. Requires importing
        `./agenix.nix` alongside this module (and the agenix module itself)'';

      secretsDir = mkOption {
        description = "Directory holding the `<keyName><fileSuffix>` files.";
        type = types.nullOr types.path;
        default = null;
      };

      fileSuffix = mkOption {
        description = "Suffix appended to `keyName` to form the `rekeyFile` name.";
        type = types.str;
        default = ".age";
      };

      generatorScript = mkOption {
        description = ''
          agenix-rekey `generator.script` for the declared secrets — `"ssh"`
          makes the key materialise on first rekey instead of being pasted in
          by hand. `null` declares no generator (plain agenix).
        '';
        type = types.nullOr types.str;
        default = "ssh";
      };

      owner = mkOption {
        description = "Owner of the decrypted key.";
        type = types.str;
        default = "root";
      };

      mode = mkOption {
        description = ''
          Mode of the decrypted key. The Nix daemon reads it as root; ssh
          refuses a world-readable private key outright.
        '';
        type = types.str;
        default = "0400";
      };

      extraSecretConfig = mkOption {
        description = "Merged into every declared `age.secrets.<name>` attrset.";
        type = types.attrsOf types.anything;
        default = { };
      };
    };

    benchmark = {
      enable = mkEnableOption ''
        the `nix-builder-bench` harness in `environment.systemPackages`,
        preloaded with this host's routed builders'';

      targets = mkOption {
        description = ''
          Explicit benchmark targets, `label -> command reading a program on
          stdin` (usually `ssh <alias>`, or the literal word `local`). `null`
          derives them from this host's routed builders, so you benchmark
          exactly the machines you actually offload to, through exactly the
          ssh aliases the builds use.
        '';
        type = types.nullOr (types.attrsOf types.str);
        default = null;
        example = {
          candidate = "ssh candidate-builder";
          here = "local";
        };
      };

      benchmarks = mkOption {
        description = "Benchmarks to run. `disk_rand` and `mem_bw` also exist.";
        type = types.listOf types.str;
        default = [
          "sysinfo"
          "cpu_single"
          "cpu_multi"
          "disk_seq"
          "nix_eval"
          "nix_build"
        ];
      };

      runs = mkOption {
        description = "hyperfine measurement runs per benchmark.";
        type = types.ints.positive;
        default = 3;
      };

      warmupRuns = mkOption {
        description = ''
          hyperfine warmup runs. DISCARDED from the statistics — this is what
          keeps a cold page cache and a cold Nix database out of the median.
        '';
        type = types.ints.unsigned;
        default = 1;
      };

      diskSizeMB = mkOption {
        description = "fio working-set size, MiB.";
        type = types.ints.positive;
        default = 256;
      };

      toolPackages = mkOption {
        description = ''
          Flake references realised ONCE on the remote, inside the single
          `nix shell` every benchmark runs under. Requires flakes and a
          `nixpkgs` registry entry on the remote; pin a revision here if you
          want the toolchain identical across a measurement campaign.
        '';
        type = types.listOf types.str;
        default = [
          "nixpkgs#hyperfine"
          "nixpkgs#fio"
          "nixpkgs#coreutils"
          "nixpkgs#jq"
          "nixpkgs#bash"
        ];
      };
    };

    selectedNames = mkOption {
      description = "Read-only: builder names this host resolved to, in order.";
      type = types.listOf types.str;
      readOnly = true;
      default = selectedNames;
      defaultText = lib.literalMD "computed from `routes` / `defaultRoute` / `excludedHosts`";
    };

    keyNames = mkOption {
      description = ''
        Read-only: DE-DUPLICATED `keyName`s of the builders this host routes
        to, and nothing else. Wire your secret manager to this rather than to
        the whole table — a host that routes to no builder must declare no
        secret, and several builders commonly share one keypair.
      '';
      type = types.listOf types.str;
      readOnly = true;
      default = keyNames;
      defaultText = lib.literalMD "unique `keyName`s of `selectedNames`";
    };
  };

  config = mkIf (cfg.enable && selected != [ ]) (
    lib.mkMerge [
      {
        assertions =
          [
            {
              assertion = !cfg.strictRoutes || unknownNames == [ ];
              message = ''
                nix.remoteBuilders: host ${thisHost} routes to builders that are
                not in the table: ${lib.concatStringsSep ", " unknownNames}
              '';
            }
          ]
          ++ map (b: {
            assertion =
              let
                id = identityOf b;
              in
              id == null || !(lib.hasPrefix builtins.storeDir id);
            message = ''
              nix.remoteBuilders: builder "${b.hostName}" has an identityFile
              inside the Nix store. Store paths are world-readable, and
              nixpkgs' own nix.buildMachines.*.sshKey documentation requires a
              path in the local filesystem for exactly this reason.
            '';
          }) selected
          ++ map (b: {
            assertion = b.systems != [ ];
            message = ''
              nix.remoteBuilders: builder "${b.hostName}" declares no systems.
              nixpkgs asserts on this too, but with a message that does not
              name the table entry.
            '';
          }) selected;

        nix.distributedBuilds = cfg.distributedBuilds;
        nix.settings.builders-use-substitutes = cfg.useSubstitutes;

        nix.buildMachines = map (b: {
          inherit (b)
            hostName
            systems
            maxJobs
            speedFactor
            protocol
            mandatoryFeatures
            publicHostKey
            ;
          sshUser = b.user;
          sshKey = identityOf b;
          supportedFeatures = b.features;
        }) selected;
      }

      # mkBefore is load-bearing, not stylistic: ssh_config takes the FIRST
      # value it obtains for each keyword, and nixpkgs appends its own
      # `Host *` section AFTER programs.ssh.extraConfig
      # (nixos/modules/programs/ssh.nix). Emitting builder blocks first is
      # what makes `ControlMaster no` reachable at all.
      (mkIf cfg.ssh.manageClientConfig {
        programs.ssh.extraConfig = lib.mkBefore (lib.concatMapStrings sshBlock selected);
      })

      (mkIf cfg.benchmark.enable {
        environment.systemPackages = [ benchPackage ];
      })
    ]
  );
}
