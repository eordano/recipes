{ pkgs, ... }:
let
  inherit (pkgs) lib;

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

  matching = {
    v1 = mkProbe { version = "1.0"; };
    v1-rebuilt = mkProbe {
      version = "1.0";
      salt = "dependency-bump";
    };
    v2 = mkProbe { version = "2.0"; };
    v3-unstable = mkProbe { version = "2.1-unstable-2026-07-28"; };
  };

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

  denyByDefault = {
    services.opensnitch.settings = {
      DefaultAction = "deny";
      ProcMonitorMethod = "ebpf";
      LogLevel = 1;
    };
    system.extraDependencies = probeClosure;
    system.stateVersion = "25.05";
  };
  withEvalGates =
    script:
    assert lib.assertMsg (lintFailures == [ ]) (
      "eval-time lint checks failed: " + lib.concatMapStringsSep "; " (c: c.what) lintFailures
    );
    script;
in
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

  testScript = withEvalGates ''
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
