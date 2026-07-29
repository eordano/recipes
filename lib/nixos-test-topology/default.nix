# nixos-test-topology
#
# A topology builder + fixture library for `pkgs.testers.runNixOSTest`.
#
# `mkTopology` takes a declarative description of subnets and hosts and returns
# per-node NixOS modules that give every machine EXACTLY the addresses you
# asked for -- no phantom addresses from the test framework's own automatic
# assignment. It also returns the addresses back to you as plain strings so the
# testScript can reference them without hardcoding anything twice.
#
# The fixtures are the other half: an option/secret stub that materialises
# secrets at the SAME path convention the real provider uses, a source-address
# echo server, and a netfilter FORWARD-hook packet counter -- the instrument
# that turns "the request was blocked" into "the request reached the forward
# hook AND was blocked".
#
#   topo = (import ./lib/nixos-test-topology).mkTopology {
#     subnets = { guest.vlan = 1; uplink.vlan = 2; };
#     hosts = {
#       browser = { addresses.guest = 50; via = "gateway"; };
#       gateway = { addresses = { guest = 1; uplink = 1; }; forward = true; };
#       origin  = { addresses.uplink = 80; via = "gateway"; };
#     };
#   };
#
#   nodes.browser = { ... }: { imports = [ topo.nodes.browser ]; };
#   # -> browser has 10.1.0.50/24 on eth1 and nothing else.
#   # -> topo.ip.origin.uplink == "10.2.0.80"
#
# See README.md for the four traps this exists to defuse, with upstream
# file:line citations. `examples.filteringRouter` at the bottom is a complete,
# runnable three-node test that exercises every one of them.

let
  inherit (builtins)
    attrNames
    concatLists
    concatStringsSep
    elem
    filter
    foldl'
    hasAttr
    head
    isInt
    length
    listToAttrs
    map
    mapAttrs
    sort
    toString
    ;

  nvp = name: value: { inherit name value; };
  uniq = foldl' (acc: x: if elem x acc then acc else acc ++ [ x ]) [ ];
  hasDup = xs: length (uniq xs) != length xs;
  compact = filter (x: x != null);
  sortedNames = set: sort (a: b: a < b) (attrNames set);

  subnetKeys = [
    "vlan"
    "prefix"
    "prefix6"
    "prefixLength"
    "prefixLength6"
    "interface"
  ];
  hostKeys = [
    "addresses"
    "via"
    "forward"
    "primary"
  ];

  mkTopology =
    {
      subnets,
      hosts,
      defaultPrefixLength ? 24,
    }:
    let
      mkSubnet =
        sname: s:
        let
          vlan = s.vlan or (throw "mkTopology: subnet '${sname}' has no `vlan`");
        in
        if !isInt vlan || vlan < 1 || vlan > 255 then
          throw (
            "mkTopology: subnet '${sname}' vlan ${toString vlan} is out of range 1..255. "
            + "vlan 0 would name the interface eth0 (already taken by the VM's own NIC) and "
            + "nixos/lib/qemu-common.nix `zeroPad` throws above 255."
          )
        else
          {
            name = sname;
            inherit vlan;
            # Deliberately NOT 192.168.<vlan>.x: that is the framework's own
            # auto-assignment range (nixos/lib/testing/network.nix:41). Staying
            # off it means a stray auto-assigned address shows up as an obvious
            # 192.168.* stranger instead of silently duplicating one of yours.
            prefix = s.prefix or "10.${toString vlan}.0";
            prefix6 = s.prefix6 or null;
            prefixLength = s.prefixLength or defaultPrefixLength;
            prefixLength6 = s.prefixLength6 or 64;
            # eth<vlan>, not eth<ordinal>: the interface name then encodes the
            # subnet and is the same on every host, so testScripts and firewall
            # rules can name it without knowing a host's interface ordering.
            interface = s.interface or "eth${toString vlan}";
          };

      sub = mapAttrs mkSubnet subnets;

      hostSubnets = hname: sortedNames hosts.${hname}.addresses;
      octet = hname: sname: hosts.${hname}.addresses.${sname};
      addrOf = hname: sname: "${sub.${sname}.prefix}.${toString (octet hname sname)}";
      addr6Of = hname: sname: "${sub.${sname}.prefix6}${toString (octet hname sname)}";
      primaryOf = hname: hosts.${hname}.primary or (head (hostSubnets hname));

      vlanList = map (s: sub.${s}.vlan) (sortedNames sub);
      ifaceList = map (s: sub.${s}.interface) (sortedNames sub);

      errors = compact (
        [
          (
            if hasDup vlanList then
              "two subnets share a vlan id (${concatStringsSep ", " (map toString vlanList)})"
            else
              null
          )
          (
            if hasDup ifaceList then
              "two subnets share an interface name (${concatStringsSep ", " ifaceList})"
            else
              null
          )
          (
            if elem "eth0" ifaceList then
              "'eth0' is the VM's own NIC and cannot be a topology interface"
            else
              null
          )
        ]
        ++ concatLists (
          map (
            sname:
            map (k: if elem k subnetKeys then null else "subnet '${sname}': unknown key '${k}'") (
              attrNames subnets.${sname}
            )
          ) (sortedNames subnets)
        )
        ++ concatLists (
          map (
            hname:
            map (
              k:
              if elem k hostKeys then
                null
              else
                "host '${hname}': unknown key '${k}' -- did you mean `addresses.${k}`?"
            ) (attrNames hosts.${hname})
          ) (sortedNames hosts)
        )
        ++ map (
          hname: if hasAttr "addresses" hosts.${hname} then null else "host '${hname}' has no `addresses`"
        ) (sortedNames hosts)
        ++ concatLists (
          map (
            hname:
            map (
              sname:
              if !hasAttr sname sub then
                "host '${hname}' references unknown subnet '${sname}'"
              else if !isInt (octet hname sname) || octet hname sname < 1 || octet hname sname > 254 then
                "host '${hname}' octet on subnet '${sname}' must be 1..254"
              else
                null
            ) (attrNames (hosts.${hname}.addresses or { }))
          ) (sortedNames hosts)
        )
        ++ map (
          sname:
          let
            occupied = map (hname: octet hname sname) (
              filter (hname: hasAttr sname (hosts.${hname}.addresses or { })) (sortedNames hosts)
            );
          in
          if hasDup occupied then "subnet '${sname}': two hosts claim the same octet" else null
        ) (sortedNames sub)
        ++ map (
          hname:
          let
            h = hosts.${hname};
          in
          if !(h ? via) then
            null
          else if !hasAttr h.via hosts then
            "host '${hname}' has `via = \"${h.via}\"` but there is no such host"
          else if
            filter (s: hasAttr s (hosts.${h.via}.addresses or { })) (attrNames (h.addresses or { })) == [ ]
          then
            "host '${hname}' has `via = \"${h.via}\"` but they share no subnet"
          else
            null
        ) (sortedNames hosts)
      );

      check = v: if errors == [ ] then v else throw ("mkTopology:\n  " + concatStringsSep "\n  " errors);

      # Every host/subnet address gets a stable `<host>-<subnet>` name. The
      # framework's own /etc/hosts only ever publishes each node's PRIMARY
      # address (nixos/lib/testing/network.nix:96-99), so on a multi-homed node
      # the bare hostname resolves to one subnet only. Use these aliases when a
      # peer must reach a specific leg.
      extraHostsText = concatStringsSep "\n" (
        concatLists (
          map (hname: map (sname: "${addrOf hname sname} ${hname}-${sname}") (hostSubnets hname)) (
            sortedNames hosts
          )
        )
      );

      nodeModule =
        hname:
        let
          h = hosts.${hname};
          snames = hostSubnets hname;
          primary = primaryOf hname;
          viaSubnet = if h ? via then head (filter (s: hasAttr s hosts.${h.via}.addresses) snames) else null;
        in
        {
          config,
          lib,
          ...
        }:
        {
          # THE fix. `virtualisation.vlans = [ N ]` desugars to an interface with
          # `assignIP = true` (nixos/modules/virtualisation/guest-networking-options.nix:50),
          # which makes the framework hand out 192.168.<vlan>.<alphabetical rank>.
          # Declaring the interface directly with assignIP = false leaves the
          # addressing entirely to us.
          virtualisation.interfaces = listToAttrs (
            map (
              s:
              nvp sub.${s}.interface {
                vlan = sub.${s}.vlan;
                assignIP = false;
              }
            ) snames
          );

          networking = {
            useDHCP = lib.mkDefault false;

            interfaces = listToAttrs (
              map (
                s:
                nvp sub.${s}.interface (
                  {
                    ipv4.addresses = [
                      {
                        address = addrOf hname s;
                        prefixLength = sub.${s}.prefixLength;
                      }
                    ];
                  }
                  // lib.optionalAttrs (sub.${s}.prefix6 != null) {
                    ipv6.addresses = [
                      {
                        address = addr6Of hname s;
                        prefixLength = sub.${s}.prefixLength6;
                      }
                    ];
                  }
                )
              ) snames
            );

            # With assignIP = false the framework's own `ipInterfaces` binding is
            # empty, so it still DEFINES primaryIPAddress -- as "" -- and this
            # node would vanish from every peer's /etc/hosts. mkForce is required
            # (a plain definition is a conflict, not an override); the one
            # upstream test that uses assignIP does exactly the same
            # (nixos/tests/systemd-initrd-bridge.nix:27). This is the ONE place
            # mkForce is correct here -- never on `networking.interfaces.*`.
            primaryIPAddress = lib.mkForce (addrOf hname primary);

            extraHosts = extraHostsText;
          }
          // lib.optionalAttrs (sub.${primary}.prefix6 != null) {
            primaryIPv6Address = lib.mkForce (addr6Of hname primary);
          }
          // lib.optionalAttrs (viaSubnet != null) {
            defaultGateway = {
              address = addrOf h.via viaSubnet;
              interface = sub.${viaSubnet}.interface;
            };
          };

          boot.kernel.sysctl = lib.mkIf (h.forward or false) {
            "net.ipv4.ip_forward" = 1;
            "net.ipv6.conf.all.forwarding" = 1;
          };

          assertions = [
            {
              assertion = config.virtualisation.vlans == [ ];
              message =
                "nixos-test-topology: node '${hname}' still sets `virtualisation.vlans` "
                + "(${concatStringsSep ", " (map toString config.virtualisation.vlans)}). That re-enables the "
                + "framework's automatic 192.168.<vlan>.<rank> assignment alongside the topology "
                + "addresses. Remove it -- mkTopology declares `virtualisation.interfaces` instead.";
            }
          ]
          ++ map (s: {
            assertion = length config.networking.interfaces.${sub.${s}.interface}.ipv4.addresses == 1;
            message =
              "nixos-test-topology: node '${hname}' interface ${sub.${s}.interface} ended up with "
              + "${toString (length config.networking.interfaces.${sub.${s}.interface}.ipv4.addresses)} "
              + "IPv4 addresses, expected 1. `networking.interfaces.<i>.ipv4.addresses` is a LIST, so a "
              + "second definition MERGES rather than replaces. Find the other definition; do not paper "
              + "over it with mkForce (that leaves networking.primaryIPAddress pointing at the address "
              + "you forced away).";
          }) snames
          ++ [
            {
              assertion = config.networking.primaryIPAddress == addrOf hname primary;
              message =
                "nixos-test-topology: node '${hname}' has primaryIPAddress "
                + "'${config.networking.primaryIPAddress}', expected '${addrOf hname primary}'. Something "
                + "else is defining it; every peer's /etc/hosts is built from this value.";
            }
          ];
        };
    in
    check {
      # Normalised inputs, for callers that want to introspect.
      subnets = sub;
      inherit hosts;

      # topo.ip.<host>.<subnet> -> "10.1.0.50"
      ip = listToAttrs (
        map (hname: nvp hname (listToAttrs (map (s: nvp s (addrOf hname s)) (hostSubnets hname)))) (
          sortedNames hosts
        )
      );

      # topo.ip6.<host>.<subnet>, only for subnets that declared a prefix6.
      ip6 = listToAttrs (
        map (
          hname:
          nvp hname (
            listToAttrs (
              map (s: nvp s (addr6Of hname s)) (filter (s: sub.${s}.prefix6 != null) (hostSubnets hname))
            )
          )
        ) (sortedNames hosts)
      );

      # topo.iface.<subnet> -> "eth1"; same on every host by construction.
      iface = listToAttrs (map (s: nvp s sub.${s}.interface) (sortedNames sub));

      # topo.vlan.<subnet> -> 1
      vlan = listToAttrs (map (s: nvp s sub.${s}.vlan) (sortedNames sub));

      # topo.cidr.<subnet> -> "10.1.0.0/24"
      cidr = listToAttrs (
        map (s: nvp s "${sub.${s}.prefix}.0/${toString sub.${s}.prefixLength}") (sortedNames sub)
      );

      # topo.alias.<host>.<subnet> -> "browser-guest", resolvable on every node.
      alias = listToAttrs (
        map (hname: nvp hname (listToAttrs (map (s: nvp s "${hname}-${s}") (hostSubnets hname)))) (
          sortedNames hosts
        )
      );

      # topo.nodes.<host> -> a NixOS module to `imports = [ ... ]` into that node.
      nodes = listToAttrs (map (hname: nvp hname (nodeModule hname)) (sortedNames hosts));

      inherit extraHostsText;
    };

  fixtures = {

    # Declare foreign option paths so a module under test can read or set an
    # option tree whose real provider (home-manager, a private module set, ...)
    # is not imported in the test. `paths` maps a dotted option path to the
    # default value.
    optionStub =
      paths:
      { lib, ... }:
      {
        options = foldl' lib.recursiveUpdate { } (
          lib.mapAttrsToList (
            p: default:
            lib.setAttrByPath (lib.splitString "." p) (
              lib.mkOption {
                type = lib.types.anything;
                inherit default;
                description = "Test stub for `${p}`.";
              }
            )
          ) paths
        );
      };

    # A stand-in secrets provider.
    #
    # `runDir` MUST match the real provider's default path convention, because
    # modules under test reference `config.<namespace>.secrets.<n>.path` and a
    # stub that seeds somewhere else makes the test green while the real
    # deployment reads a file that does not exist.
    #
    # Seeding is an ORDERING problem, not a file-creation problem. The seeder is
    # a `Type=oneshot` + `RemainAfterExit=true` unit and every declared consumer
    # gets an explicit `Requires=`/`After=` edge to it, so a consumer restarted
    # mid-test still finds its secret.
    secretsStub =
      {
        namespace ? "age",
        runDir ? "/run/agenix",
        contents ? { },
        defaultContent ? "nixos-test-topology placeholder secret",
        consumers ? [ ],
        unitName ? "test-secrets-seed",
      }:
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        declared = lib.attrByPath [ namespace "secrets" ] { } config;
        seedFor =
          name: s:
          let
            text = contents.${name} or defaultContent;
          in
          ''
            install -D -m ${s.mode} -o ${s.owner} -g ${s.group} \
              ${pkgs.writeText "test-secret-${name}" text} ${lib.escapeShellArg s.path}
          '';
      in
      {
        options = lib.setAttrByPath [ namespace "secrets" ] (
          lib.mkOption {
            default = { };
            description = "Test stub for the `${namespace}.secrets` option surface.";
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }:
                {
                  options = {
                    name = lib.mkOption {
                      type = lib.types.str;
                      default = name;
                    };
                    file = lib.mkOption {
                      type = lib.types.nullOr lib.types.path;
                      default = null;
                    };
                    rekeyFile = lib.mkOption {
                      type = lib.types.nullOr lib.types.path;
                      default = null;
                    };
                    path = lib.mkOption {
                      type = lib.types.str;
                      default = "${runDir}/${name}";
                    };
                    mode = lib.mkOption {
                      type = lib.types.str;
                      default = "0400";
                    };
                    owner = lib.mkOption {
                      type = lib.types.str;
                      default = "root";
                    };
                    group = lib.mkOption {
                      type = lib.types.str;
                      default = "root";
                    };
                    symlink = lib.mkOption {
                      type = lib.types.bool;
                      default = true;
                    };
                  };
                }
              )
            );
          }
        );

        config.systemd.services = lib.mkMerge (
          [
            {
              ${unitName} = {
                description = "Seed stub secrets for the NixOS test";
                wantedBy = [ "multi-user.target" ];
                before = [ "multi-user.target" ] ++ consumers;
                # Non-root owners need the users to exist first; harmless when
                # the unit is absent.
                after = [ "systemd-sysusers.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  set -eu
                  install -d -m 0751 ${lib.escapeShellArg runDir}
                  ${lib.concatStrings (lib.mapAttrsToList seedFor declared)}
                '';
              };
            }
          ]
          ++ map (unit: {
            ${lib.removeSuffix ".service" unit} = {
              after = [ "${unitName}.service" ];
              requires = [ "${unitName}.service" ];
            };
          }) consumers
        );
      };

    # HTTP server that answers with the client's source address. The measuring
    # instrument for "did this request actually get NATed / routed", as opposed
    # to "did the request succeed".
    httpEcho =
      {
        name ? "http-echo",
        port ? 8080,
        listen ? "0.0.0.0",
      }:
      { pkgs, ... }:
      {
        systemd.services.${name} = {
          description = "HTTP server echoing the client's source address";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            DynamicUser = true;
            Restart = "on-failure";
            ExecStart =
              let
                script = pkgs.writeText "${name}.py" ''
                  from http.server import HTTPServer, BaseHTTPRequestHandler

                  class Handler(BaseHTTPRequestHandler):
                      def do_GET(self):
                          self.send_response(200)
                          self.send_header("Content-Type", "text/plain")
                          self.end_headers()
                          self.wfile.write(self.client_address[0].encode())
                      def log_message(self, *args):
                          pass

                  HTTPServer(("${listen}", ${toString port}), Handler).serve_forever()
                '';
              in
              "${pkgs.python3}/bin/python3 ${script}";
          };
        };
      };

    # A counting base chain on the netfilter FORWARD hook.
    #
    # A routing/filtering test is only meaningful if the packets actually reach
    # the forward hook. Put the guest and the destination on the same subnet and
    # they ARP each other directly: the request succeeds, the filter never runs,
    # and the test is green while proving nothing. Read this counter and the
    # illusion collapses.
    #
    # Implemented as its own nf_tables table at a low priority with `policy
    # accept`, so it counts and falls through whatever firewall backend is in
    # use. It deliberately does NOT go through `networking.firewall.extraCommands`,
    # which nixpkgs hard-asserts must be empty under the nftables backend
    # (nixos/modules/services/networking/firewall-nftables.nix:65).
    forwardCounter =
      {
        name ? "topo_fwd",
        family ? "inet",
        priority ? -300,
        match ? "",
      }:
      { pkgs, ... }:
      let
        rules = pkgs.writeText "${name}-counter.nft" ''
          table ${family} ${name} {}
          delete table ${family} ${name}
          table ${family} ${name} {
            counter hits { }
            chain forward {
              type filter hook forward priority ${toString priority}; policy accept;
              ${match} counter name hits
            }
          }
        '';
        count = pkgs.writeShellScriptBin "${name}-count" ''
          exec ${pkgs.nftables}/bin/nft list counter ${family} ${name} hits \
            | ${pkgs.gawk}/bin/awk '$1 == "packets" { print $2; exit }'
        '';
        reset = pkgs.writeShellScriptBin "${name}-reset" ''
          exec ${pkgs.nftables}/bin/nft reset counter ${family} ${name} hits >/dev/null
        '';
      in
      {
        environment.systemPackages = [
          count
          reset
          pkgs.nftables
        ];
        systemd.services."${name}-counter" = {
          description = "FORWARD-hook packet counter for the NixOS test";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-pre.target"
            "nftables.service"
            "firewall.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.nftables}/bin/nft -f ${rules}";
            ExecStop = "${pkgs.nftables}/bin/nft delete table ${family} ${name}";
          };
        };
      };
  };

  # A complete, runnable three-node test. Build it with:
  #
  #   nix build --impure --expr '
  #     let pkgs = import <nixpkgs> {}; in
  #     (import ./lib/nixos-test-topology).examples.filteringRouter { inherit pkgs; }'
  #
  # Node names are deliberately alphabetical-adversarial: "browser" < "gateway"
  # < "origin", so the framework would rank them 1/2/3 and hand out
  # 192.168.1.1, 192.168.1.2, 192.168.1.3. The test asserts no 192.168.* address
  # exists anywhere, which is the regression test for that whole trap family.
  examples.filteringRouter =
    { pkgs }:
    let
      topo = mkTopology {
        subnets = {
          guest.vlan = 1;
          uplink.vlan = 2;
        };
        hosts = {
          browser = {
            addresses.guest = 50;
            via = "gateway";
          };
          gateway = {
            addresses = {
              guest = 1;
              uplink = 1;
            };
            forward = true;
          };
          origin = {
            addresses.uplink = 80;
            via = "gateway";
          };
        };
      };
      blockedPort = 9090;
      echoPort = 8080;
    in
    pkgs.testers.runNixOSTest {
      name = "nixos-test-topology-example";

      nodes = {
        browser =
          { pkgs, ... }:
          {
            imports = [ topo.nodes.browser ];
            networking.firewall.enable = false;
            environment.systemPackages = [ pkgs.curl ];
            system.stateVersion = "25.05";
          };

        gateway =
          { ... }:
          {
            imports = [
              topo.nodes.gateway
              (fixtures.forwardCounter { })
            ];
            networking.firewall.enable = false;
            networking.nftables.enable = true;
            networking.nftables.tables = {
              demo_filter = {
                family = "inet";
                content = ''
                  chain forward {
                    type filter hook forward priority 10; policy accept;
                    tcp dport ${toString blockedPort} counter drop
                  }
                '';
              };
              demo_nat = {
                family = "ip";
                content = ''
                  chain postrouting {
                    type nat hook postrouting priority 100; policy accept;
                    oifname "${topo.iface.uplink}" masquerade
                  }
                '';
              };
            };
            system.stateVersion = "25.05";
          };

        origin =
          { config, pkgs, ... }:
          {
            imports = [
              topo.nodes.origin
              (fixtures.httpEcho { port = echoPort; })
              (fixtures.httpEcho {
                name = "http-echo-blocked";
                port = blockedPort;
              })
              (fixtures.secretsStub {
                contents.api-token = "s3cr3t-from-the-stub";
                consumers = [ "token-reader.service" ];
              })
            ];
            networking.firewall.enable = false;
            system.stateVersion = "25.05";

            # A module "under test" declaring a secret the ordinary way. The stub
            # materialises it at the declared path -- which is the real
            # provider's default, /run/agenix/<name>.
            age.secrets.api-token = { };

            systemd.services.token-reader = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                ${pkgs.coreutils}/bin/install -m 0444 \
                  ${config.age.secrets.api-token.path} /run/token-reader-saw
              '';
            };
          };
      };

      testScript = ''
        start_all()
        browser.wait_for_unit("multi-user.target")
        gateway.wait_for_unit("topo_fwd-counter.service")
        origin.wait_for_unit("http-echo.service")
        origin.wait_for_unit("http-echo-blocked.service")
        origin.wait_for_unit("token-reader.service")

        with subtest("no phantom framework addresses anywhere"):
            for node, name in ((browser, "browser"), (gateway, "gateway"), (origin, "origin")):
                addrs = node.succeed("ip -4 -o addr show scope global")
                assert "192.168." not in addrs, (
                    f"{name} carries a framework auto-assigned 192.168.* address:\n{addrs}"
                )

        with subtest("each topology interface has exactly one address"):
            assert browser.succeed(
                "ip -4 -o addr show dev ${topo.iface.guest} | wc -l"
            ).strip() == "1"
            assert gateway.succeed(
                "ip -4 -o addr show dev ${topo.iface.uplink} | wc -l"
            ).strip() == "1"

        with subtest("addresses are the ones the topology declared"):
            browser.succeed("ip -4 addr show dev ${topo.iface.guest} | grep -q ${topo.ip.browser.guest}/24")
            origin.succeed("ip -4 addr show dev ${topo.iface.uplink} | grep -q ${topo.ip.origin.uplink}/24")

        with subtest("guest and destination are on different subnets"):
            # If this ever becomes false the FORWARD hook stops being involved
            # and every filtering assertion below turns into a tautology.
            assert "${topo.cidr.guest}" != "${topo.cidr.uplink}"
            route = browser.succeed("ip route get ${topo.ip.origin.uplink}")
            assert "via ${topo.ip.gateway.guest}" in route, (
                f"origin is on-link from browser, so nothing will transit the router:\n{route}"
            )

        with subtest("allowed traffic transits the FORWARD hook and is NATed"):
            gateway.succeed("topo_fwd-reset")
            seen = browser.succeed(
                "curl -sf --max-time 10 http://${topo.ip.origin.uplink}:${toString echoPort}"
            ).strip()
            assert seen == "${topo.ip.gateway.uplink}", (
                f"origin saw source {seen}, expected the gateway's uplink address "
                "${topo.ip.gateway.uplink} -- traffic did not transit the router"
            )
            forwarded = int(gateway.succeed("topo_fwd-count").strip())
            assert forwarded > 0, "FORWARD hook counted 0 packets"

        with subtest("blocked traffic is dropped AT the forward hook, not merely absent"):
            gateway.succeed("topo_fwd-reset")
            browser.fail(
                "curl -sf --max-time 5 http://${topo.ip.origin.uplink}:${toString blockedPort}"
            )
            forwarded = int(gateway.succeed("topo_fwd-count").strip())
            assert forwarded > 0, (
                "the request failed but the FORWARD hook saw 0 packets -- it never reached "
                "the router, so this proves nothing about the filter"
            )

        with subtest("per-leg host aliases resolve"):
            browser.succeed("getent hosts ${topo.alias.origin.uplink}")
            browser.succeed("getent hosts ${topo.alias.gateway.guest}")

        with subtest("stub secret landed at the real provider's default path"):
            origin.succeed("test -f /run/agenix/api-token")
            assert origin.succeed("cat /run/token-reader-saw").strip() == "s3cr3t-from-the-stub"

        with subtest("consumer cannot start before the seeder"):
            origin.succeed("systemctl stop token-reader.service")
            origin.succeed("rm -f /run/token-reader-saw /run/agenix/api-token")
            origin.succeed("systemctl stop test-secrets-seed.service")
            origin.succeed("systemctl start token-reader.service")
            # Requires= pulled the seeder back in, so the secret exists again.
            origin.succeed("test -f /run/agenix/api-token")
            assert origin.succeed("cat /run/token-reader-saw").strip() == "s3cr3t-from-the-stub"

        print("=== nixos-test-topology example passed ===")
      '';
    };
in
{
  inherit mkTopology fixtures;
  inherit (fixtures)
    optionStub
    secretsStub
    httpEcho
    forwardCounter
    ;
  inherit examples;
}
