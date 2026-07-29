{
  config,
  lib,
  ...
}:
let
  inherit (lib)
    concatMapStrings
    concatStringsSep
    filterAttrs
    mapAttrs
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    optional
    optionalAttrs
    types
    ;

  cfg = config.services.opensnitchStorePathRules;

  # RE2 (Go's regexp, what opensnitchd compiles rule regexes with) has no
  # \Q..\E, so literal path components have to be escaped by hand. Backslash
  # first, or every escape we add gets escaped again.
  escapeRe =
    s:
    builtins.replaceStrings
      [
        "\\"
        "."
        "+"
        "*"
        "?"
        "("
        ")"
        "["
        "]"
        "{"
        "}"
        "|"
        "^"
        "$"
      ]
      [
        "\\\\"
        "\\."
        "\\+"
        "\\*"
        "\\?"
        "\\("
        "\\)"
        "\\["
        "\\]"
        "\\{"
        "\\}"
        "\\|"
        "\\^"
        "\\$"
      ]
      s;

  # "bin/foo" -> { dir = "bin/"; leaf = "foo"; }, both already regex-escaped.
  splitSubpath =
    subpath:
    let
      parts = lib.splitString "/" subpath;
    in
    {
      dir = concatMapStrings (p: escapeRe p + "/") (lib.init parts);
      leaf = lib.last parts;
    };

  # The whole point of the recipe: a matcher for a *shape* of store path, not
  # for one hash. See README "Trap 1".
  binaryRegex =
    b:
    if b.regex != null then
      b.regex
    else
      let
        version = if b.versionPattern != null then b.versionPattern else cfg.versionPattern;
        prefix = "^/nix/store/${cfg.storeHashPattern}-${escapeRe b.pname}${version}/";
        parts = splitSubpath b.subpath;
        leaf =
          if b.wrapped then "(\\.)?${escapeRe parts.leaf}(-wrapped)?" else escapeRe parts.leaf;
        tail = if b.pathRegex != null then b.pathRegex else parts.dir + leaf;
      in
      prefix + tail + "$";

  binaryRegexes = mapAttrs (_: binaryRegex) cfg.binaries;

  operand = type: name: data: {
    inherit type;
    operand = name;
    sensitive = cfg.sensitive;
    inherit data;
  };

  portOperand =
    ports:
    if builtins.length ports == 1 then
      operand "simple" "dest.port" (toString (builtins.head ports))
    else
      operand "regexp" "dest.port" "^(${concatStringsSep "|" (map toString ports)})$";

  processOperand =
    r:
    if r.processPath != null then
      operand "simple" "process.path" r.processPath
    else if r.processRegex != null then
      operand "regexp" "process.path" r.processRegex
    else
      operand "regexp" "process.path" binaryRegexes.${r.binary};

  # Operand order is fixed — process, network, port, host — so that a rule's
  # generated JSON is a pure function of its spec and never depends on the
  # order somebody happened to write the options in.
  operandsOf =
    r:
    optional (r.binary != null || r.processRegex != null || r.processPath != null) (processOperand r)
    ++ optional (r.network != null) (operand "network" "dest.network" r.network)
    ++ optional (r.ports != [ ]) (portOperand r.ports)
    ++ optional (r.host != null) (operand "simple" "dest.host" r.host)
    ++ optional (r.hostRegex != null) (operand "regexp" "dest.host" r.hostRegex)
    ++ r.extraOperands;

  ruleJson =
    name: r:
    let
      ops = operandsOf r;
    in
    {
      name = if r.ruleName != null then r.ruleName else name;
      created = if r.created != null then r.created else cfg.created;
      inherit (r) enabled action duration;
      operator =
        if builtins.length ops == 1 then
          builtins.head ops
        else
          {
            type = "list";
            operand = "list";
            list = ops;
          };
    }
    // optionalAttrs (r.precedence != null) { inherit (r) precedence; };

  generated = mapAttrs ruleJson (filterAttrs (_: r: r.enable) cfg.rules);

  binaryType = types.submodule (
    { name, ... }:
    {
      options = {
        pname = mkOption {
          description = ''
            Derivation name as it appears in the store path, i.e. the text
            between the hash and the version. Matched literally (regex-escaped).
          '';
          type = types.str;
          default = name;
          defaultText = lib.literalMD "the attribute name";
        };

        versionPattern = mkOption {
          description = ''
            Regex fragment matching everything between `pname` and the first
            path separator. `null` uses {option}`services.opensnitchStorePathRules.versionPattern`.
            Must start with a separator (`-`) or be optional, otherwise
            `foo` also matches `foobar`.
          '';
          type = types.nullOr types.str;
          default = null;
          example = "-[0-9.]*";
        };

        subpath = mkOption {
          description = ''
            Path of the executable *inside* the store path, matched literally
            (regex-escaped). Ignored when `pathRegex` or `regex` is set.
          '';
          type = types.str;
          default = "bin/${name}";
          defaultText = lib.literalMD "`bin/` + the attribute name";
          example = "libexec/chromium/chromium";
        };

        wrapped = mkOption {
          description = ''
            Also match the `makeWrapper` payload: `.NAME-wrapped` next to
            `NAME`. Set this for anything nixpkgs wraps — the wrapper `exec`s
            the payload, so the path opensnitchd sees is the *payload's*.
            See README "Trap 2".
          '';
          type = types.bool;
          default = false;
        };

        pathRegex = mkOption {
          description = ''
            Raw regex (NOT escaped) for everything after the store path's
            first `/`. Overrides `subpath` and `wrapped`.
          '';
          type = types.nullOr types.str;
          default = null;
          example = "bin/python3(\\.[0-9]+)?";
        };

        regex = mkOption {
          description = ''
            Raw regex (NOT escaped) for the whole `process.path`. Overrides
            every other option here. Still linted.
          '';
          type = types.nullOr types.str;
          default = null;
        };
      };
    }
  );

  ruleType = types.submodule (
    { ... }:
    {
      options = {
        enable = mkOption {
          description = ''
            Generate this rule at all. `false` removes the rule file, which is
            NOT the same as `enabled = false` (that ships a disabled rule).
          '';
          type = types.bool;
          default = true;
        };

        ruleName = mkOption {
          description = "Rule `name` field. Defaults to the attribute name.";
          type = types.nullOr types.str;
          default = null;
        };

        enabled = mkOption {
          description = "Rule `enabled` field, as understood by opensnitchd.";
          type = types.bool;
          default = true;
        };

        action = mkOption {
          description = "What opensnitchd does with a matching connection.";
          type = types.enum [
            "allow"
            "deny"
            "reject"
          ];
          default = "allow";
        };

        duration = mkOption {
          description = ''
            Lifetime of the rule. Anything other than "always" makes a
            declarative rule expire at runtime, which is almost never what a
            Nix-generated rule wants.
          '';
          type = types.str;
          default = "always";
        };

        precedence = mkOption {
          description = ''
            Evaluate this rule before non-precedence rules. `null` omits the
            field entirely (opensnitchd then treats it as false).
          '';
          type = types.nullOr types.bool;
          default = null;
        };

        created = mkOption {
          description = ''
            Rule `created` timestamp. `null` uses the module-wide constant.
            MUST be constant — see README "Trap 6".
          '';
          type = types.nullOr types.str;
          default = null;
        };

        binary = mkOption {
          description = ''
            Key into {option}`services.opensnitchStorePathRules.binaries`,
            turned into a `process.path` regexp operand.
          '';
          type = types.nullOr types.str;
          default = null;
        };

        processRegex = mkOption {
          description = "Raw `process.path` regexp, instead of `binary`.";
          type = types.nullOr types.str;
          default = null;
        };

        processPath = mkOption {
          description = ''
            Exact `process.path`. Only correct for paths that are stable across
            rebuilds (`/usr/bin/...`, `/run/current-system/sw/bin/...` is NOT —
            opensnitchd reports the resolved target, not the symlink).
          '';
          type = types.nullOr types.str;
          default = null;
        };

        network = mkOption {
          description = "`dest.network` CIDR operand.";
          type = types.nullOr types.str;
          default = null;
          example = "192.168.0.0/16";
        };

        ports = mkOption {
          description = ''
            Destination ports. One port emits a `simple` operand, several emit
            a single anchored alternation regexp. Empty list omits the operand
            — see README "Trap 4" before adding one.
          '';
          type = types.listOf types.port;
          default = [ ];
        };

        host = mkOption {
          description = "Exact `dest.host`. See README \"Trap 4\".";
          type = types.nullOr types.str;
          default = null;
        };

        hostRegex = mkOption {
          description = "`dest.host` regexp. Prefer this over `host`.";
          type = types.nullOr types.str;
          default = null;
        };

        extraOperands = mkOption {
          description = ''
            Raw operand attrsets appended after the generated ones, for
            operands this DSL does not model (`dest.ip`, `user.id`,
            `process.command`, `iface.out`, ...).
          '';
          type = types.listOf (types.attrsOf types.anything);
          default = [ ];
        };
      };
    }
  );

  # ---- lints -------------------------------------------------------------
  processRegexes =
    lib.mapAttrsToList (n: b: {
      what = "binaries.${n}";
      re = binaryRegex b;
    }) cfg.binaries
    ++ lib.concatLists (
      mapAttrsToList (
        n: r: optional (r.processRegex != null) {
          what = "rules.${n}.processRegex";
          re = r.processRegex;
        }
      ) cfg.rules
    );

  unanchored = builtins.filter (
    p: !(lib.hasPrefix "^" p.re && lib.hasSuffix "$" p.re)
  ) processRegexes;

  unrooted = builtins.filter (p: !(lib.hasPrefix "^/nix/store/" p.re || lib.hasPrefix "^/" p.re)) processRegexes;

  danglingBinaryRefs = builtins.filter (n: !(cfg.binaries ? ${n})) (
    lib.concatLists (mapAttrsToList (_: r: optional (r.binary != null) r.binary) cfg.rules)
  );

  emptyRules = mapAttrsToList (n: _: n) (
    filterAttrs (_: r: r.enable && operandsOf r == [ ]) cfg.rules
  );
in
{
  options.services.opensnitchStorePathRules = {
    enable = mkEnableOption "declarative OpenSnitch rules keyed on store-path *shapes*";

    storeHashPattern = mkOption {
      description = ''
        Regex fragment matching the store hash. The default deliberately
        excludes `-` and `/`, so the fragment cannot run past the first
        component of the store path. Never use `.*` here.
      '';
      type = types.str;
      default = "[0-9a-z]+";
    };

    versionPattern = mkOption {
      description = ''
        Default regex fragment between `pname` and the first `/`.

        `-[^/]*` cannot cross a directory boundary. `-.*` can (RE2's `.`
        matches `/`), which is needed for executables that live under a
        second versioned directory — and is also how an over-broad rule
        accidentally matches an unrelated binary. See README "Trap 3".
      '';
      type = types.str;
      default = "-[^/]*";
      example = "-.*";
    };

    sensitive = mkOption {
      description = ''
        Rule `sensitive` field (case-sensitive matching). Emitted on every
        generated operand.
      '';
      type = types.bool;
      default = false;
    };

    created = mkOption {
      description = ''
        `created` timestamp stamped into every generated rule. A constant on
        purpose: anything derived from the current time makes the rule's store
        path change on every evaluation. See README "Trap 6".
      '';
      type = types.str;
      default = "1970-01-01T00:00:00Z";
    };

    binaries = mkOption {
      description = ''
        Named `process.path` matchers. Each one describes the *shape* of a
        store path, so it keeps matching after the package is rebuilt.
      '';
      type = types.attrsOf binaryType;
      default = { };
      example = lib.literalExpression ''
        {
          curl = { };                                        # bin/curl
          tailscaled = { pname = "tailscale"; subpath = "bin/tailscaled"; wrapped = true; };
          chromium = { versionPattern = "(-unwrapped)?-[^/]*"; subpath = "libexec/chromium/chromium"; };
        }
      '';
    };

    rules = mkOption {
      description = ''
        Rules, in a small DSL that compiles to
        {option}`services.opensnitch.rules`.
      '';
      type = types.attrsOf ruleType;
      default = { };
      example = lib.literalExpression ''
        {
          curl-web = { binary = "curl"; ports = [ 80 443 ]; };
          block-telemetry = { action = "deny"; hostRegex = "^telemetry\\..*$"; };
        }
      '';
    };

    extraRules = mkOption {
      description = ''
        Raw rules merged into {option}`services.opensnitch.rules` verbatim,
        for anything the DSL does not express (and for reproducing a
        hand-written rule byte-for-byte).
      '';
      type = types.attrsOf (types.attrsOf types.anything);
      default = { };
    };

    requireEbpf = mkOption {
      description = ''
        Assert `settings.ProcMonitorMethod == "ebpf"`. The `proc` monitor
        reads `/proc/<pid>/exe` after the fact and loses short-lived
        processes, so `process.path` rules silently stop matching for exactly
        the programs (updaters, `curl` one-shots) they were written for.
      '';
      type = types.bool;
      default = true;
    };

    lint = {
      anchors = mkOption {
        description = ''
          Assert every `process.path` regex is anchored with `^` and `$`.
          Unanchored is a substring match in RE2 — `bin/nc` would also match
          `.../bin/ncat`.
        '';
        type = types.bool;
        default = true;
      };

      absolutePaths = mkOption {
        description = ''
          Assert every `process.path` regex is rooted at an absolute path.
        '';
        type = types.bool;
        default = true;
      };

      emptyRules = mkOption {
        description = ''
          Assert no rule compiles to zero operands. A rule with no operands
          matches *everything*, so an `allow` typo silently disables the
          firewall.
        '';
        type = types.bool;
        default = true;
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = danglingBinaryRefs == [ ];
        message =
          "services.opensnitchStorePathRules: rules reference undefined binaries: "
          + concatStringsSep ", " danglingBinaryRefs;
      }
      {
        assertion = !cfg.lint.emptyRules || emptyRules == [ ];
        message =
          "services.opensnitchStorePathRules: these rules have no operands and would match every connection: "
          + concatStringsSep ", " emptyRules;
      }
      {
        assertion = !cfg.lint.anchors || unanchored == [ ];
        message =
          "services.opensnitchStorePathRules: unanchored process.path regex (RE2 matches substrings) in: "
          + concatStringsSep ", " (map (p: p.what) unanchored);
      }
      {
        assertion = !cfg.lint.absolutePaths || unrooted == [ ];
        message =
          "services.opensnitchStorePathRules: process.path regex is not rooted at an absolute path in: "
          + concatStringsSep ", " (map (p: p.what) unrooted);
      }
      {
        assertion =
          !cfg.requireEbpf || (config.services.opensnitch.settings.ProcMonitorMethod or "ebpf") == "ebpf";
        message = ''
          services.opensnitchStorePathRules: process.path rules need
          services.opensnitch.settings.ProcMonitorMethod = "ebpf"; the "proc"
          and "ftrace" monitors miss short-lived processes. Set requireEbpf =
          false if you accept that.
        '';
      }
    ];

    services.opensnitch = {
      enable = lib.mkDefault true;
      rules = generated // cfg.extraRules;
    };
  };
}
