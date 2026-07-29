# NixOS VM test for the opensnitch-store-path-rules module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from a flake:
#
#   pkgs.callPackage ./modules/opensnitch-store-path-rules/test.nix { }
#
# What it proves.
#
# The recipe exists because opensnitchd identifies a process by its ABSOLUTE
# executable path, which on NixOS is a content-hashed store path that changes
# whenever the package -- or any of its dependencies -- is rebuilt. A rule
# holding a literal path silently stops matching after the next upgrade, and
# under `DefaultAction = "deny"` that failure is a black hole: traffic just
# stops. So the test has to demonstrate two things at once, and the second one
# is what makes it more than a snapshot:
#
#   A. the generated rule matches the CURRENT store path of the target binary,
#      checked against the path resolved at runtime inside the guest, and
#   B. it keeps matching after the package is rebuilt at a NEW store path --
#      whether the rebuild changed only the hash (a dependency bump) or the
#      version string too.
#
# A naive module that stamped the authoring-time path into the rule passes (A)
# and fails (B). That module is not hypothetical here: the `pinned` node runs
# exactly it -- a hand-written `processPath` rule holding one literal store
# path -- and the test asserts it BREAKS on the rebuilt binaries while the
# recipe's rule keeps working. If the recipe ever regressed into pinning a
# path, `shaped` and `pinned` would agree and the test would fail.
#
# Both halves are proved twice, at two different levels:
#
#   * behaviourally, end to end: `DefaultAction = "deny"`, opensnitchd running
#     with the eBPF process monitor, and a real HTTP request to another VM. An
#     allowed probe must fetch the page; a denied one must not. This is the
#     only lane that proves the rule is actually IN the packet path -- and
#     every deny is paired with a success from a byte-identical binary at a
#     different store path on the same node to the same destination in the same
#     run, so "it failed" cannot be confused with "the network was down".
#
#   * statically, on the rule file the module actually wrote to
#     /var/lib/opensnitch/rules: the generated regex is matched against store
#     paths resolved with `realpath` in the guest, and asserted to contain no
#     literal store hash at all.
#
# Not covered: the GUI/database side of opensnitch (Trap 7), and rule
# precedence ordering between declarative and runtime rules.
#
# Topology: `lib/nixos-test-topology` assigns the addresses. Note that its
# Trap 4 (client and destination must sit on different subnets) does NOT apply
# here -- opensnitch filters the client's OWN outbound connections on the
# client itself, so there is no forward hook to bypass. The equivalent
# "did the filter actually run" guard is the paired allow/deny control
# described above.
{ pkgs, ... }:
let
  lib = pkgs.lib;

  topology = import ../../lib/nixos-test-topology;

  topo = topology.mkTopology {
    subnets.lan.vlan = 1;
    hosts = {
      origin.addresses.lan = 10;
      shaped.addresses.lan = 20;
      pinned.addresses.lan = 30;
    };
  };

  echoPort = 8080;
  originUrl = "http://${topo.ip.origin.lan}:${toString echoPort}/";

  # ---------------------------------------------------------------------------
  # Probe binaries.
  #
  # Each one is a real, working curl at a store path we control the SHAPE of.
  # Copying the ELF (rather than symlinking or wrapping) matters: opensnitchd
  # reports the path of the executable that was exec'd, so the copy must be the
  # thing on disk. Its RPATH still points at curl's own store outputs, which the
  # reference scanner picks up, so the closure comes along for free.
  #
  # `salt` only exists to change the derivation hash, which is what produces
  # "same package, same version, different store path" -- the dependency-bump
  # rebuild that quietly breaks a hand-written rule.
  # ---------------------------------------------------------------------------
  mkProbe =
    {
      pname ? "netprobe",
      version,
      dir ? "bin",
      leaf ? "netprobe",
      salt ? "",
    }:
    let
      drv = pkgs.runCommand "${pname}-${version}" { inherit salt; } ''
        mkdir -p "$out/${dir}"
        cp ${lib.getExe pkgs.curl} "$out/${dir}/${leaf}"
        chmod 0755 "$out/${dir}/${leaf}"
      '';
    in
    {
      inherit drv;
      store = "${drv}";
      exe = "${drv}/${dir}/${leaf}";
    };

  # Must match `binaries.netprobe` (plain) after any rebuild.
  matching = {
    v1 = mkProbe { version = "1.0"; };
    v1-rebuilt = mkProbe {
      version = "1.0";
      salt = "dependency-bump";
    };
    v2 = mkProbe { version = "2.0"; };
    v3-unstable = mkProbe { version = "2.1-unstable-2026-07-28"; };
  };

  # Must match `binaries.wrapprobe` (wrapped = true): both the wrapper and the
  # `.NAME-wrapped` payload it exec's. See README "Trap 2".
  wrapped = {
    wrapper = mkProbe {
      pname = "wrapprobe";
      version = "1.0";
      leaf = "wrapprobe";
    };
    payload = mkProbe {
      pname = "wrapprobe";
      version = "1.0";
      leaf = ".wrapprobe-wrapped";
      salt = "payload";
    };
  };

  # Must NOT match anything. These are the assertions an over-broad regex --
  # `.*` for the hash, a missing `$`, a missing `^` -- fails.
  decoys = {
    foreign-pname = mkProbe {
      pname = "otherprobe";
      version = "1.0";
    };
    pname-prefix-collision = mkProbe {
      pname = "netprobelike";
      version = "1.0";
    };
    leaf-suffix = mkProbe {
      version = "1.0";
      leaf = "netprobe-helper";
    };
    wrong-subdir = mkProbe {
      version = "1.0";
      dir = "libexec";
    };
    # `wrapped = false` on `binaries.netprobe`, so the payload must NOT match --
    # which is precisely why Trap 2 exists.
    unlisted-wrapper-payload = mkProbe {
      version = "1.0";
      leaf = ".netprobe-wrapped";
      salt = "payload";
    };
  };

  allProbes = matching // wrapped // decoys;
  exePaths = lib.mapAttrs (_: p: p.exe) allProbes;
  storePaths = lib.mapAttrs (_: p: p.store) allProbes;
  probeClosure = lib.mapAttrsToList (_: p: p.drv) allProbes;

  # ---------------------------------------------------------------------------
  # Eval-time lint checks.
  #
  # The module's assertions are its own defence against the ways a store-path
  # rule goes silently wrong (unanchored regex, zero operands, a `proc` monitor
  # that loses short-lived processes). They are dead code unless something
  # actually exercises them, and a VM cannot: an assertion failure aborts the
  # evaluation before there is a machine to run. So they are checked here, in a
  # plain non-VM evaluation, by reading `config.assertions` directly.
  # ---------------------------------------------------------------------------
  failedMessages =
    extra:
    map (a: a.message) (
      builtins.filter (a: !a.assertion)
        (import (pkgs.path + "/nixos/lib/eval-config.nix") {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            ./default.nix
            {
              boot.loader.grub.enable = false;
              system.stateVersion = "25.05";
              fileSystems."/" = {
                device = "/dev/vda";
                fsType = "ext4";
              };
            }
            extra
          ];
        }).config.assertions
    );

  saysAny = needle: msgs: lib.any (m: lib.hasInfix needle m) msgs;

  lintChecks = [
    {
      what = "a well-formed config raises no assertion";
      ok =
        failedMessages {
          services.opensnitchStorePathRules = {
            enable = true;
            binaries.netprobe = { };
            rules.netprobe-egress.binary = "netprobe";
          };
        } == [ ];
    }
    {
      what = "an unanchored process.path regex is rejected";
      ok = saysAny "unanchored" (failedMessages {
        services.opensnitchStorePathRules = {
          enable = true;
          rules.loose.processRegex = "/nix/store/.*/bin/nc";
        };
      });
    }
    {
      what = "a rule that compiles to zero operands is rejected";
      ok = saysAny "no operands" (failedMessages {
        services.opensnitchStorePathRules = {
          enable = true;
          rules.everything.action = "allow";
        };
      });
    }
    {
      what = "a rule referencing an undefined binary is rejected";
      ok = saysAny "undefined binaries" (failedMessages {
        services.opensnitchStorePathRules = {
          enable = true;
          rules.typo.binary = "netprobbe";
        };
      });
    }
    {
      what = "requireEbpf rejects the proc process monitor";
      ok = saysAny "ProcMonitorMethod" (failedMessages {
        services.opensnitchStorePathRules = {
          enable = true;
          binaries.netprobe = { };
          rules.netprobe-egress.binary = "netprobe";
        };
        services.opensnitch.settings.ProcMonitorMethod = "proc";
      });
    }
  ];

  lintFailures = builtins.filter (c: !c.ok) lintChecks;

  # Shared by both filtering nodes: deny by default, eBPF process monitor.
  denyByDefault = {
    services.opensnitch.settings = {
      DefaultAction = "deny";
      ProcMonitorMethod = "ebpf";
      LogLevel = 1;
    };
    system.extraDependencies = probeClosure;
    system.stateVersion = "25.05";
  };
in
assert lib.assertMsg (lintFailures == [ ]) (
  "eval-time lint checks failed: " + lib.concatMapStringsSep "; " (c: c.what) lintFailures
);
pkgs.testers.runNixOSTest {
  name = "opensnitch-store-path-rules";

  nodes = {
    origin =
      { ... }:
      {
        imports = [
          topo.nodes.origin
          (topology.fixtures.httpEcho { port = echoPort; })
        ];
        networking.firewall.enable = false;
        system.stateVersion = "25.05";
      };

    # The recipe: rules keyed on the SHAPE of a store path.
    shaped =
      { ... }:
      {
        imports = [
          ./default.nix
          topo.nodes.shaped
          denyByDefault
        ];

        services.opensnitchStorePathRules = {
          enable = true;
          binaries = {
            netprobe = { };
            wrapprobe.wrapped = true;
          };
          rules = {
            netprobe-egress = {
              binary = "netprobe";
              action = "allow";
            };
            wrapprobe-egress = {
              binary = "wrapprobe";
              action = "allow";
            };
          };
        };
      };

    # The naive alternative, as a live control: one hand-written rule holding
    # the literal store path of v1. It is what an adopter writes before reading
    # the README, and the test asserts it breaks on every rebuild.
    pinned =
      { ... }:
      {
        imports = [
          ./default.nix
          topo.nodes.pinned
          denyByDefault
        ];

        services.opensnitchStorePathRules = {
          enable = true;
          rules.netprobe-egress = {
            processPath = matching.v1.exe;
            action = "allow";
          };
        };
      };
  };

  testScript = ''
    import json
    import re

    EXE = ${builtins.toJSON exePaths}
    STORE = ${builtins.toJSON storePaths}
    MATCHING = ${builtins.toJSON (builtins.attrNames matching)}
    WRAPPED = ${builtins.toJSON (builtins.attrNames wrapped)}
    DECOYS = ${builtins.toJSON (builtins.attrNames decoys)}
    URL = ${builtins.toJSON originUrl}
    SHAPED_IP = ${builtins.toJSON topo.ip.shaped.lan}
    PINNED_IP = ${builtins.toJSON topo.ip.pinned.lan}
    RULES = "/var/lib/opensnitch/rules"


    def store_hash(path):
        return path.split("/")[3].split("-")[0]


    def fetch(machine, probe, name):
        """Run a probe and return (ok, body). --connect-timeout bounds a drop."""
        rc, out = machine.execute(
            f"{EXE[probe]} --silent --show-error --connect-timeout 5 --max-time 15 {URL}"
        )
        machine.log(f"probe {probe} ({name}): rc={rc} out={out!r}")
        return rc == 0, out.strip()


    start_all()

    origin.wait_for_unit("http-echo.service")
    origin.wait_for_open_port(${toString echoPort})

    for m in (shaped, pinned):
        m.wait_for_unit("multi-user.target")
        m.wait_for_unit("opensnitchd.service")
        # The eBPF monitor is the only one that reliably sees short-lived
        # processes; if it silently fell back, every process.path claim below
        # would be meaningless.
        #
        # wait_until_succeeds, not succeed: opensnitchd goes `active` roughly
        # half a second before it logs the module load, so a bare grep here is
        # a race that fails maybe one run in five.
        m.wait_until_succeeds(
            r"journalctl -u opensnitchd --grep '\[eBPF\] module loaded: /nix/store/.*/etc/opensnitchd/opensnitch\.o'",
            timeout=60,
        )

    with subtest("the probe store paths are genuinely distinct"):
        # Everything below is vacuous if the "rebuilt" packages landed on the
        # same path. Assert the premise before relying on it.
        paths = {k: STORE[k] for k in MATCHING}
        assert len(set(paths.values())) == len(paths), f"store paths collided: {paths}"
        # v1 and v1-rebuilt are the same pname AND version: only the hash moved,
        # which is the dependency-bump case a literal rule cannot survive.
        assert STORE["v1"] != STORE["v1-rebuilt"]
        assert STORE["v1"].split("-", 1)[1] == STORE["v1-rebuilt"].split("-", 1)[1]

    with subtest("the generated rule matches the CURRENT store path, and pins no hash"):
        rule = json.loads(shaped.succeed(f"cat {RULES}/netprobe-egress.json"))
        op = rule["operator"]
        assert op["operand"] == "process.path", op
        assert op["type"] == "regexp", op
        pattern = op["data"]
        shaped.log(f"generated process.path regex: {pattern}")

        # Go's regexp.MatchString is an unanchored search, so mirror it with
        # re.search rather than re.fullmatch; the module's own lint is what
        # guarantees the ^...$ that makes the two equivalent here.
        for name in MATCHING:
            resolved = shaped.succeed(f"realpath {EXE[name]}").strip()
            assert resolved.startswith("/nix/store/"), resolved
            assert re.search(pattern, resolved), f"{name}: {resolved} !~ {pattern}"

        # No literal store hash anywhere in the rule: this is what separates a
        # shape from a snapshot.
        blob = shaped.succeed(f"cat {RULES}/netprobe-egress.json")
        for name in MATCHING:
            h = store_hash(STORE[name])
            assert len(h) > 20, h
            assert h not in blob, f"rule pins the hash of {name}"

        for name in DECOYS:
            resolved = shaped.succeed(f"realpath {EXE[name]}").strip()
            assert not re.search(pattern, resolved), f"decoy {name} matched: {resolved}"

    with subtest("the wrapped= binary matches both the wrapper and its payload"):
        rule = json.loads(shaped.succeed(f"cat {RULES}/wrapprobe-egress.json"))
        pattern = rule["operator"]["data"]
        for name in WRAPPED:
            resolved = shaped.succeed(f"realpath {EXE[name]}").strip()
            assert re.search(pattern, resolved), f"{name}: {resolved} !~ {pattern}"

    with subtest("the hand-written control really does pin one literal path"):
        rule = json.loads(pinned.succeed(f"cat {RULES}/netprobe-egress.json"))
        op = rule["operator"]
        assert op["type"] == "simple", op
        assert op["data"] == EXE["v1"], op
        assert store_hash(STORE["v1"]) in op["data"]

    with subtest("allowed: every rebuild of the target binary still reaches origin"):
        for name in list(MATCHING) + list(WRAPPED):
            ok, body = fetch(shaped, name, "allowed")
            assert ok, f"{name} was blocked but should have been allowed"
            # The echo server answers with the client's source address, so this
            # is proof the request reached the far end, not merely that curl
            # exited 0 against something local.
            assert body == SHAPED_IP, f"{name}: origin saw {body!r}, expected {SHAPED_IP}"

    with subtest("denied: near-miss store paths do not inherit the allow"):
        # Each of these is a byte-identical curl to the ones that just
        # succeeded, on the same machine, to the same URL, seconds apart. The
        # ONLY difference is the store path. That is what rules out "the
        # network was down" as an explanation for the failure.
        for name in DECOYS:
            ok, body = fetch(shaped, name, "denied")
            assert not ok, f"decoy {name} was allowed; the rule is too broad"

    with subtest("a node with no matching rule at all is denied (default-deny is live)"):
        # Belt and braces: if DefaultAction were not actually in force, every
        # deny above would be an illusion. `pinned` has no rule for wrapprobe.
        ok, _ = fetch(pinned, "wrapper", "no rule")
        assert not ok, "pinned allowed an unruled binary; DefaultAction is not in force"

    with subtest("THE POINT: the pinned rule survives no rebuild, the shaped rule survives all"):
        # Baseline: the pinned node's rule works for the exact path it names,
        # so its networking, its opensnitchd and its rule file are all healthy.
        ok, body = fetch(pinned, "v1", "pinned baseline")
        assert ok, "pinned node could not reach origin even for the pinned path"
        assert body == PINNED_IP, f"origin saw {body!r}, expected {PINNED_IP}"

        # And now the upgrade. Same package, rebuilt. The literal rule stops
        # matching -- silently, with no error anywhere -- while the shaped rule
        # on the other node already allowed all three above.
        for name in ("v1-rebuilt", "v2", "v3-unstable"):
            ok, _ = fetch(pinned, name, "pinned after rebuild")
            assert not ok, (
                f"pinned rule matched {name}: the control is broken, so the "
                f"shaped node's success proves nothing"
            )
  '';
}
