{ pkgs, ... }:
let
  inherit (pkgs) lib;

  topology = import ../../lib/nixos-test-topology;

  topo = topology.mkTopology {
    subnets = {
      lan = {
        vlan = 1;
        interface = "lan0";
      };
      wan = {
        vlan = 2;
        interface = "wan0";
      };
      svc = {
        vlan = 3;
        interface = "svc0";
      };
    };
    hosts = {
      client = {
        addresses.lan = 10;
        via = "plainrtr";
      };
      unguarded = {
        addresses.lan = 11;
        via = "plainrtr";
      };
      plainrtr = {
        addresses = {
          lan = 1;
          wan = 1;
          svc = 1;
        };
        forward = true;
        primary = "lan";
      };
      exita = {
        addresses = {
          wan = 20;
          svc = 20;
        };
        via = "plainrtr";
        forward = true;
        primary = "wan";
      };
      exitb = {
        addresses = {
          wan = 30;
          svc = 30;
        };
        via = "plainrtr";
        forward = true;
        primary = "wan";
      };
      echo = {
        addresses.svc = 80;
        via = "plainrtr";
      };
    };
  };

  echoPort = 8080;
  wgPort = 51820;

  keys = {
    exita = {
      priv = "eM43S4HZ7iptoJxVdWj8tSl8ETfUc8OlIv6rV4Lr61Q=";
      pub = "Kh6GJtCMGc74DLHP6hv0Mx7SNxIuLJjRkpSQqI7Pky4=";
    };
    exitb = {
      priv = "cM6vrLg0VLAsioUkGF7kipPlzXiI5sGiB7OALqlqN0Q=";
      pub = "gyhpcn6U+Ujgh7F8fOFEbLt61UqfgfiMRrBMsPnPf2g=";
    };
    clientAlpha = {
      priv = "uIflNjbSVwap9FPOsChLsKBU0Bl3B51w2rHqAkkv63s=";
      pub = "pxcqT6XdIljepKJh9NnRKMgw/LfO1cZ9ZuzwdJGXrBQ=";
    };
    clientBeta = {
      priv = "KGPb1JPaUqBhbxzYc032K/WuPBgavmmCQoRq7+qJ73w=";
      pub = "YQZ/DhxFCTBPJNYTwUt1gnvd02mFigWfZ4K+kJXLwVI=";
    };
    unguarded = {
      priv = "iElm8xPjP30FspfnXG4rDUqHyQZMtDuSvbJo+AzU8nc=";
      pub = "uwZWpXa6Bdz688zemEaPpnMVpN7A/PQsjwmhuQBaQyE=";
    };
  };

  tun = {
    alphaServer = "10.100.0.1";
    alphaClient = "10.100.0.2";
    alphaUnguarded = "10.100.0.3";
    betaServer = "10.101.0.1";
    betaClient = "10.101.0.2";
  };

  pinnedGid = 3000;
  uids = {
    alpha = 3001;
    beta = 3002;
    none = 3003;
  };

  s = toString;

  wgConf =
    {
      priv,
      address,
      peerPub,
      endpoint,
    }:
    ''
      [Interface]
      PrivateKey = ${priv}
      Address = ${address}/32

      [Peer]
      PublicKey = ${peerPub}
      Endpoint = ${endpoint}:${s wgPort}
      AllowedIPs = 0.0.0.0/0
    '';

  confs = {
    wg-exit-alpha = wgConf {
      priv = keys.clientAlpha.priv;
      address = tun.alphaClient;
      peerPub = keys.exita.pub;
      endpoint = topo.ip.exita.wan;
    };
    wg-exit-beta = wgConf {
      priv = keys.clientBeta.priv;
      address = tun.betaClient;
      peerPub = keys.exitb.pub;
      endpoint = topo.ip.exitb.wan;
    };
    wg-exit-unguarded = wgConf {
      priv = keys.unguarded.priv;
      address = tun.alphaUnguarded;
      peerPub = keys.exita.pub;
      endpoint = topo.ip.exita.wan;
    };
  };

  exitsConfig = secretPath: {
    enable = true;
    providerLabel = "TestVPN";
    exits = {
      alpha = {
        configFile = secretPath "wg-exit-alpha";
        pins.app.uid = uids.alpha;
      };
      beta = {
        configFile = secretPath "wg-exit-beta";
        pins.app = {
          uid = uids.beta;
          uidRangeRule.enable = true;
        };
      };
    };
  };

  slots =
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
          networking.nftables.enable = true;
          services.wireguardExits = exitsConfig (n: "/run/agenix/${n}");
        }
      ];
    }).config.services.wireguardExits.slots;

  expectedSlots = {
    alpha = {
      index = 0;
      interface = "wg-alpha";
      routeTable = 200;
      fwmark = 200;
      tunnelFwmark = 400;
      rulePriority = 2000;
      setupUnit = "wireguard-exit-alpha";
    };
    beta = {
      index = 1;
      interface = "wg-beta";
      routeTable = 201;
      fwmark = 201;
      tunnelFwmark = 401;
      rulePriority = 2001;
      setupUnit = "wireguard-exit-beta";
    };
  };

  slotsOk = lib.all (
    name:
    lib.all (k: slots.${name}.${k} == expectedSlots.${name}.${k}) (lib.attrNames expectedSlots.${name})
  ) (lib.attrNames expectedSlots);

  markProbe =
    probes:
    { pkgs, ... }:
    let
      names = map (p: p.name) probes;
      counters = lib.concatMapStringsSep "\n  " (
        n:
        "counter outer_${n} { }\n  counter outer_${n}_uid { }\n  counter marked_${n} { }\n  counter recursed_${n} { }"
      ) names;
      pre = lib.concatMapStringsSep "\n    " (
        p:
        "meta mark ${s p.tunnelFwmark} counter name outer_${p.name}\n    "
        + "meta mark ${s p.tunnelFwmark} meta skuid ${s p.uid} counter name outer_${p.name}_uid"
      ) probes;
      post = lib.concatMapStringsSep "\n    " (
        p:
        "meta mark ${s p.fwmark} counter name marked_${p.name}\n    "
        + "meta mark ${s p.fwmark} udp dport ${s wgPort} counter name recursed_${p.name}"
      ) probes;
    in
    {
      networking.nftables.tables.guardprobe = {
        family = "inet";
        content = ''
          ${counters}

          chain premark {
            type filter hook output priority -400; policy accept;
            ${pre}
          }

          chain postmark {
            type filter hook output priority -140; policy accept;
            ${post}
          }
        '';
      };

      environment.systemPackages = [
        pkgs.nftables
        (pkgs.writeShellScriptBin "ctr" ''
          exec ${pkgs.nftables}/bin/nft list counter inet guardprobe "$1" \
            | ${pkgs.gawk}/bin/awk '$1 == "packets" { print $2; exit }'
        '')
        (pkgs.writeShellScriptBin "ctr-reset" ''
          exec ${pkgs.nftables}/bin/nft reset counters table inet guardprobe >/dev/null
        '')
      ];
    };

  exitNode =
    {
      key,
      serverIP,
      peers,
    }:
    { pkgs, ... }:
    {
      imports = [
        (topology.forwardCounter {
          name = "tun_fwd";
          match = ''iifname "wg0"'';
        })
      ];

      networking.firewall.enable = false;
      networking.nftables.enable = true;
      networking.nftables.tables.exitnat = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority 100; policy accept;
            oifname "${topo.iface.svc}" masquerade
          }
        '';
      };

      boot.kernel.sysctl = {
        "net.ipv4.conf.all.rp_filter" = 0;
        "net.ipv4.conf.default.rp_filter" = 0;
      };

      environment.systemPackages = [ pkgs.wireguard-tools ];
      system.stateVersion = "25.05";

      systemd.services.wg-server = {
        description = "WireGuard endpoint standing in for a VPN provider";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [
          pkgs.wireguard-tools
          pkgs.iproute2
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          umask 077
          install -d -m 0700 /run/wg-server
          printf '%s\n' ${lib.escapeShellArg key} > /run/wg-server/key
          ip link del wg0 2>/dev/null || true
          ip link add wg0 type wireguard
          wg set wg0 listen-port ${s wgPort} private-key /run/wg-server/key
          ${lib.concatMapStringsSep "\n  " (p: "wg set wg0 peer ${p.pub} allowed-ips ${p.allowedIPs}") peers}
          ip addr add ${serverIP}/24 dev wg0
          ip link set wg0 up mtu 1280
        '';
      };
    };

  pinnedUsers = {
    users.groups.pinned.gid = pinnedGid;
    users.users = lib.mapAttrs' (
      n: uid:
      lib.nameValuePair "pin-${n}" {
        isSystemUser = true;
        inherit uid;
        group = "pinned";
      }
    ) uids;
  };
in
assert lib.assertMsg slotsOk ''
  services.wireguardExits.slots no longer matches the numbering this test
  asserts on. Got: ${lib.generators.toPretty { } slots}
'';
pkgs.testers.runNixOSTest {
  name = "wireguard-per-uid-exits";

  nodes = {
    plainrtr = {
      imports = [ topo.nodes.plainrtr ];
      networking.firewall.enable = false;
      system.stateVersion = "25.05";
    };

    echo = {
      imports = [
        topo.nodes.echo
        (topology.httpEcho { port = echoPort; })
      ];
      networking.firewall.enable = false;
      system.stateVersion = "25.05";
    };

    exita = {
      imports = [
        topo.nodes.exita
        (exitNode {
          key = keys.exita.priv;
          serverIP = tun.alphaServer;
          peers = [
            {
              pub = keys.clientAlpha.pub;
              allowedIPs = "${tun.alphaClient}/32,${topo.ip.client.lan}/32";
            }
            {
              pub = keys.unguarded.pub;
              allowedIPs = "${tun.alphaUnguarded}/32,${topo.ip.unguarded.lan}/32";
            }
          ];
        })
      ];
    };

    exitb = {
      imports = [
        topo.nodes.exitb
        (exitNode {
          key = keys.exitb.priv;
          serverIP = tun.betaServer;
          peers = [
            {
              pub = keys.clientBeta.pub;
              allowedIPs = "${tun.betaClient}/32";
            }
          ];
        })
      ];
    };

    client =
      { config, pkgs, ... }:
      {
        imports = [
          ./default.nix
          topo.nodes.client
          pinnedUsers
          (markProbe [
            {
              name = "alpha";
              inherit (expectedSlots.alpha) fwmark tunnelFwmark;
              uid = uids.alpha;
            }
            {
              name = "beta";
              inherit (expectedSlots.beta) fwmark tunnelFwmark;
              uid = uids.beta;
            }
          ])
          (topology.secretsStub {
            contents = {
              inherit (confs) wg-exit-alpha wg-exit-beta;
            };
            consumers = [
              "wireguard-exit-alpha.service"
              "wireguard-exit-beta.service"
            ];
          })
        ];

        age.secrets.wg-exit-alpha = { };
        age.secrets.wg-exit-beta = { };

        networking.firewall.enable = false;
        networking.nftables.enable = true;
        system.stateVersion = "25.05";

        services.wireguardExits = exitsConfig (n: config.age.secrets.${n}.path);

        environment.systemPackages = [
          pkgs.curl
          pkgs.wireguard-tools
        ];
      };

    unguarded =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        guarded = config.services.wireguardExits.nftRuleset;
        guardClause = "meta mark != ${s expectedSlots.alpha.tunnelFwmark} ";
        stripped = builtins.replaceStrings [ guardClause ] [ "" ] guarded;
      in
      {
        imports = [
          ./default.nix
          topo.nodes.unguarded
          pinnedUsers
          (markProbe [
            {
              name = "alpha";
              inherit (expectedSlots.alpha) fwmark tunnelFwmark;
              uid = uids.alpha;
            }
          ])
          (topology.secretsStub {
            contents = {
              inherit (confs) wg-exit-unguarded;
            };
            consumers = [ "wireguard-exit-alpha.service" ];
          })
        ];

        age.secrets.wg-exit-unguarded = { };

        networking.firewall.enable = false;
        networking.nftables.enable = true;
        system.stateVersion = "25.05";

        environment.systemPackages = [
          pkgs.curl
          pkgs.wireguard-tools
        ];

        services.wireguardExits = {
          enable = true;
          providerLabel = "TestVPN";
          markBackend = "manual";
          exits.alpha = {
            configFile = config.age.secrets.wg-exit-unguarded.path;
            pins.app.uid = uids.alpha;
          };
        };

        networking.nftables.ruleset = lib.mkAfter stripped;

        assertions = [
          {
            assertion = stripped != guarded;
            message =
              "wireguard-per-uid-exits test: the negative control did not actually strip "
              + "anything. The generated marking rule no longer contains '${guardClause}', "
              + "so the `unguarded` node is identical to the guarded one and the guard "
              + "subtest would pass for free. Ruleset was:\n${guarded}";
          }
        ];
      };
  };

  testScript = ''
    ECHO = "${topo.ip.echo.svc}:${s echoPort}"

    def as_uid(uid, cmd):
        return f"setpriv --reuid={uid} --regid=${s pinnedGid} --clear-groups {cmd}"

    def curl(uid, timeout=20):
        return as_uid(uid, f"curl -sf --max-time {timeout} http://{ECHO}")

    def fetch(uid):
        return client.succeed(curl(uid)).strip()

    def reset_all():
        client.succeed("ctr-reset")
        exita.succeed("tun_fwd-reset")
        exitb.succeed("tun_fwd-reset")

    def ctr(node, name):
        return int(node.succeed(f"ctr {name}").strip())

    def counters():
        return {
            "marked_alpha": ctr(client, "marked_alpha"),
            "marked_beta": ctr(client, "marked_beta"),
            "fwd_alpha": int(exita.succeed("tun_fwd-count").strip()),
            "fwd_beta": int(exitb.succeed("tun_fwd-count").strip()),
        }

    start_all()

    plainrtr.wait_for_unit("multi-user.target")
    echo.wait_for_unit("http-echo.service")
    for node in (exita, exitb):
        node.wait_for_unit("wg-server.service")
        node.wait_for_unit("tun_fwd-counter.service")
    client.wait_for_unit("multi-user.target")
    client.wait_for_unit("wireguard-exit-alpha.service")
    client.wait_for_unit("wireguard-exit-beta.service")
    client.wait_for_unit("wireguard-exit-pin-beta-app.service")
    unguarded.wait_for_unit("multi-user.target")
    unguarded.wait_for_unit("wireguard-exit-alpha.service")

    with subtest("no phantom framework addresses anywhere"):
        for node, name in (
            (client, "client"),
            (unguarded, "unguarded"),
            (echo, "echo"),
            (exita, "exita"),
            (exitb, "exitb"),
            (plainrtr, "plainrtr"),
        ):
            addrs = node.succeed("ip -4 -o addr show scope global")
            assert "192.168." not in addrs, (
                f"{name} carries a framework auto-assigned 192.168.* address:\n{addrs}"
            )
        # The udev rename race described at the top of this file leaves a leg
        # silently unconfigured, which then surfaces as an unrelated timeout much
        # later. Assert every multi-homed node actually got its wan address.
        for node, name, want in (
            (exita, "exita", "${topo.ip.exita.wan}"),
            (exitb, "exitb", "${topo.ip.exitb.wan}"),
            (plainrtr, "plainrtr", "${topo.ip.plainrtr.wan}"),
        ):
            addrs = node.succeed("ip -4 -o addr show scope global")
            assert want in addrs, (
                f"{name} never got its wan address {want} -- an interface rename "
                f"probably lost the race:\n{addrs}"
            )

    with subtest("the destination is NOT on-link from the client"):
        # If this ever becomes false, every routing claim below degenerates into
        # "the client ARPed the destination", which proves nothing at all.
        route = client.succeed("ip route get ${topo.ip.echo.svc}")
        assert "via ${topo.ip.plainrtr.lan}" in route, (
            f"echo is on-link from client, so no routing decision is exercised:\n{route}"
        )

    with subtest("both tunnels came up with the declared numbering"):
        for iface, table, tfwmark in (
            ("wg-alpha", 200, "0x190"),
            ("wg-beta", 201, "0x191"),
        ):
            client.succeed(f"ip link show {iface}")
            wg = client.succeed(f"wg show {iface}")
            assert f"fwmark: {tfwmark}" in wg, (
                f"{iface} does not carry its tunnel fwmark, so the guard clause "
                f"could never match anything:\n{wg}"
            )
            routes = client.succeed(f"ip route show table {table}")
            assert f"default dev {iface}" in routes, (
                f"table {table} has no default route into {iface}:\n{routes}"
            )
        rules = client.succeed("ip -4 rule")
        assert "fwmark 0xc8 lookup 200" in rules, rules
        assert "fwmark 0xc9 lookup 201" in rules, rules

    with subtest("uidRangeRule is installed only where it was asked for"):
        rules = client.succeed("ip -4 rule")
        assert "uidrange ${s uids.beta}-${s uids.beta} lookup 201" in rules, rules
        assert "uidrange ${s uids.alpha}-${s uids.alpha}" not in rules, (
            "exit alpha did not request uidRangeRule, but a uidrange rule exists "
            f"for its uid:\n{rules}"
        )
        client.fail("systemctl cat wireguard-exit-pin-alpha-app.service")

    with subtest("route lookup is uid-aware only for the uidRangeRule pin"):
        # The mark is stamped in the OUTPUT hook, i.e. after source-address
        # selection, so an unmarked lookup for the fwmark-only uid still resolves
        # to the ordinary default route. This is the documented difference
        # between the two pinning mechanisms, made visible.
        alpha_lookup = client.succeed("ip route get ${topo.ip.echo.svc} uid ${s uids.alpha}")
        assert "via ${topo.ip.plainrtr.lan}" in alpha_lookup, alpha_lookup
        beta_lookup = client.succeed("ip route get ${topo.ip.echo.svc} uid ${s uids.beta}")
        assert "dev wg-beta" in beta_lookup, beta_lookup
        assert "src ${tun.betaClient}" in beta_lookup, (
            "the uidrange rule did not make the route lookup pick the tunnel's own "
            f"source address:\n{beta_lookup}"
        )
        assert "dev wg-alpha" in client.succeed("ip route get ${topo.ip.echo.svc} mark 200")
        assert "dev wg-beta" in client.succeed("ip route get ${topo.ip.echo.svc} mark 201")

    with subtest("handshakes complete on both tunnels"):
        # First traffic through a WireGuard tunnel triggers the handshake, so the
        # very first request is allowed to be slow. Everything measured below
        # runs against warm tunnels.
        client.wait_until_succeeds(curl(${s uids.alpha}, 10), timeout=90)
        client.wait_until_succeeds(curl(${s uids.beta}, 10), timeout=90)
        for iface in ("wg-alpha", "wg-beta"):
            wg = client.succeed(f"wg show {iface}")
            assert "latest handshake" in wg, f"{iface} never completed a handshake:\n{wg}"

    with subtest("uid pinned to alpha exits through alpha, and only alpha"):
        reset_all()
        seen = fetch(${s uids.alpha})
        c = counters()
        assert seen == "${topo.ip.exita.svc}", (
            f"echo saw source {seen}; expected exita's service address "
            "${topo.ip.exita.svc}. uid ${s uids.alpha} did not exit through tunnel alpha."
        )
        assert c["marked_alpha"] > 0, (
            "the request went somewhere, but ZERO packets carried exit alpha's "
            "fwmark past the module's marking chain -- the rule was not in the path"
        )
        assert c["marked_beta"] == 0, f"packets also carried exit beta's fwmark: {c}"
        assert c["fwd_alpha"] > 0, (
            f"exita forwarded no packets in from wg0, so nothing transited the tunnel: {c}"
        )
        assert c["fwd_beta"] == 0, f"exitb also forwarded tunnel packets: {c}"

    with subtest("uid pinned to beta exits through beta, and only beta"):
        reset_all()
        seen = fetch(${s uids.beta})
        c = counters()
        assert seen == "${topo.ip.exitb.svc}", (
            f"echo saw source {seen}; expected exitb's service address "
            "${topo.ip.exitb.svc}. uid ${s uids.beta} did not exit through tunnel beta."
        )
        assert c["marked_beta"] > 0, (
            "ZERO packets carried exit beta's fwmark past the module's marking chain"
        )
        assert c["marked_alpha"] == 0, f"packets also carried exit alpha's fwmark: {c}"
        assert c["fwd_beta"] > 0, f"exitb forwarded no packets in from wg0: {c}"
        assert c["fwd_alpha"] == 0, f"exita also forwarded tunnel packets: {c}"

    with subtest("an unpinned uid is untouched and leaves by the default route"):
        reset_all()
        seen = fetch(${s uids.none})
        c = counters()
        assert seen == "${topo.ip.client.lan}", (
            f"echo saw source {seen}; expected the client's own lan address "
            "${topo.ip.client.lan}. An unpinned uid must not be diverted."
        )
        assert c["marked_alpha"] == 0 and c["marked_beta"] == 0, (
            f"an unpinned uid's packets were marked: {c}"
        )
        assert c["fwd_alpha"] == 0 and c["fwd_beta"] == 0, (
            f"an unpinned uid's packets transited an exit: {c}"
        )

    with subtest("the three uids really did produce three different sources"):
        # Guards against the whole test degenerating into "everything works" if a
        # future change made every path land on one address.
        seen = {u: fetch(u) for u in (${s uids.alpha}, ${s uids.beta}, ${s uids.none})}
        assert len(set(seen.values())) == 3, (
            f"per-uid egress is not actually per-uid: {seen}"
        )

    with subtest("the guard has something to guard against"):
        # Establishes the precondition for the negative control: encrypted OUTER
        # packets really do reach the output hook presenting the pinned uid. If
        # they did not, `meta skuid` alone would already exclude them and the
        # `meta mark !=` clause would be dead weight -- in which case stripping
        # it could not break anything and the subtest below would be theatre.
        client.succeed("ctr-reset")
        client.succeed(curl(${s uids.alpha}, 10))
        client.succeed(curl(${s uids.beta}, 10))
        outer = {n: ctr(client, f"outer_{n}") for n in ("alpha", "beta")}
        owned = {n: ctr(client, f"outer_{n}_uid") for n in ("alpha", "beta")}
        assert all(v > 0 for v in outer.values()), (
            f"no encrypted outer packets carried a tunnel fwmark: {outer}"
        )
        assert all(v > 0 for v in owned.values()), (
            "no encrypted outer packet presented a pinned uid as its socket owner "
            f"({owned}), so the recursion guard cannot fire and the negative "
            "control below proves nothing. Investigate before trusting it."
        )
        recursed = {n: ctr(client, f"recursed_{n}") for n in ("alpha", "beta")}
        assert all(v == 0 for v in recursed.values()), (
            f"an outer WireGuard datagram was marked into its own exit's table "
            f"despite the guard: {recursed}"
        )

    with subtest("NEGATIVE CONTROL: without the guard the tunnel blackholes"):
        # Same module, same exit node, same uid, same numbering as the client's
        # exit alpha -- only `meta mark != 400` is missing from the marking rule.
        ruleset = unguarded.succeed("nft list table inet wireguard-exits-mark")
        assert "meta mark != " not in ruleset, (
            f"the negative control still has a guard in its live ruleset:\n{ruleset}"
        )
        assert "skuid ${s uids.alpha}" in ruleset, ruleset

        # The tunnel itself is healthy. Handshake and keepalive packets are
        # generated by the kernel with no socket attached, so `meta skuid` never
        # matches them and the missing guard cannot touch them. Asserting this
        # first is what makes the failure below mean "the recursion killed the
        # data path" rather than "the peer was unreachable all along".
        unguarded.execute(curl(${s uids.alpha}, 12))
        unguarded.wait_until_succeeds(
            "wg show wg-alpha | grep -q 'latest handshake'", timeout=60
        )

        unguarded.succeed("ctr-reset")
        exita.succeed("tun_fwd-reset")
        unguarded.fail(curl(${s uids.alpha}, 8))

        recursed = ctr(unguarded, "recursed_alpha")
        assert recursed > 0, (
            "the request failed, but NO encrypted outer packet was marked into "
            "exit alpha's table -- so this failure is not the recursion and this "
            "subtest proves nothing about the guard"
        )
        assert ctr(unguarded, "outer_alpha_uid") > 0, (
            "no uid-owned outer packet reached the output hook on the negative control"
        )
        forwarded = int(exita.succeed("tun_fwd-count").strip())
        assert forwarded == 0, (
            f"exita forwarded {forwarded} packets in from wg0 during a request that "
            "was supposed to have been swallowed by the recursion"
        )

        # And the control side of the control: the guarded client, doing exactly
        # the same thing at the same moment, still works.
        assert client.succeed(curl(${s uids.alpha})).strip() == "${topo.ip.exita.svc}"

    print("=== wireguard-per-uid-exits: per-uid egress + recursion guard verified ===")
  '';
}
