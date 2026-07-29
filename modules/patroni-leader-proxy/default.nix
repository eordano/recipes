# patroni-leader-proxy
#
# A local HAProxy that gives PostgreSQL clients a fixed endpoint which always
# lands on the CURRENT Patroni leader. HAProxy TCP-forwards the PG port but
# health-checks Patroni's REST API: `GET /primary` returns 200 only on the
# leader and `GET /replica` returns 200 only on running replicas. The RW pool
# therefore holds exactly one live server and re-points to a new leader within
# `(inter x fall)` seconds of a failover — no client reconfig, DNS, or restart.
#
# Import it, set `nodes` to your Patroni members, enable it, and point clients
# at 127.0.0.1:<port>.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.patroni-leader-proxy;

  serverLines = lib.concatStringsSep "\n        " (
    lib.mapAttrsToList (
      name: addr: "server ${name} ${addr}:${toString cfg.pgPort} check port ${toString cfg.restApiPort}"
    ) cfg.nodes
  );

  bindLines =
    port: lib.concatStringsSep "\n        " (map (addr: "bind ${addr}:${toString port}") cfg.bindAddresses);

  rwBlock = ''
    listen patroni-rw
        ${bindLines cfg.port}
        option httpchk
        http-check send meth GET uri /primary
        http-check expect status 200
        timeout check ${cfg.checkTimeout}
        default-server init-state down inter ${cfg.checkInter} fall ${toString cfg.checkFall} rise ${toString cfg.checkRise}
        ${serverLines}
  '';

  roBlock = lib.optionalString (cfg.readPort != null) ''

    listen patroni-ro
        ${bindLines cfg.readPort}
        balance roundrobin
        option httpchk
        http-check send meth GET uri /replica
        http-check expect status 200
        timeout check ${cfg.checkTimeout}
        default-server init-state down inter ${cfg.checkInter} fall ${toString cfg.checkFall} rise ${toString cfg.checkRise}
        ${serverLines}
  '';
in
{
  options.services.patroni-leader-proxy = {
    enable = lib.mkEnableOption "Local HAProxy that routes PostgreSQL to the current Patroni leader";

    nodes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      example = {
        pg1 = "10.0.0.11";
        pg2 = "10.0.0.12";
        pg3 = "10.0.0.13";
      };
      description = ''
        The Patroni members, as an attrset of `name -> address`. `name` is the
        HAProxy server label (shown in logs / stats); `address` is the host or
        IP where that node's PostgreSQL and Patroni REST API listen. Every node
        appears in both the RW and RO pools — Patroni's REST API decides which
        one is live for each role, so you never edit this on failover.
      '';
    };

    pgPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "Port each Patroni node's PostgreSQL listens on (forwarded to by HAProxy).";
    };

    restApiPort = lib.mkOption {
      type = lib.types.port;
      default = 8008;
      description = "Port each Patroni node's REST API listens on (used for the role health check).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = ''
        Local TCP port for read-write (leader) connections. Set this to
        something other than 5432 (e.g. 15432) if this host itself runs a
        PostgreSQL/Patroni that already owns 5432.
      '';
    };

    readPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 5433;
      description = "If set, a local TCP port that round-robins across running replicas.";
    };

    bindAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1" ];
      description = ''
        Addresses HAProxy binds the read-write (and read) pools on. Defaults to
        loopback for host-local consumers. Add bridge / VM gateway IPs (e.g.
        "172.20.0.1" or "192.168.121.1") so containers and microvms on this host
        can reach the proxy. Binding a not-yet-existing bridge IP requires
        `boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;`.
      '';
    };

    checkInter = lib.mkOption {
      type = lib.types.str;
      default = "5s";
      description = ''
        HAProxy `inter` — how often the Patroni REST health check runs.
        Combined with `checkFall`, a node is marked down after
        `checkInter x checkFall`. Keep this generous over high-latency /
        cross-region links: a too-tight `inter` flaps the pool down on jitter.
      '';
    };

    checkTimeout = lib.mkOption {
      type = lib.types.str;
      default = "8s";
      description = ''
        HAProxy `timeout check`. Must comfortably exceed the worst-case latency
        of a `/primary` REST response over your slowest link (a healthy check
        across a ~150ms RTT WAN can take 1-2s).
      '';
    };

    checkFall = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Consecutive failed checks before a node is marked down (see `checkInter`).";
    };

    checkRise = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Consecutive successful checks before a node is marked up again.";
    };

    extraAfterUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tailscaled.service" ];
      description = ''
        Extra systemd units to order the HAProxy service `after`. If the health
        checks reach the Patroni nodes over a VPN / overlay network (Tailscale,
        WireGuard, ...), add that unit here: starting before the overlay is up
        trips every server to "No route to host" and leaves the RW pool empty
        for ~30s until checks recover. `network-online.target` is always included.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.haproxy = {
      enable = true;
      config = ''
        global
            maxconn 2000
            log /dev/log local0

        defaults
            mode tcp
            log global
            option tcplog
            option dontlog-normal
            timeout connect 10s
            timeout client 1h
            timeout server 1h

        ${rwBlock}${roBlock}
      '';
    };

    systemd.services.haproxy = {
      after = [ "network-online.target" ] ++ cfg.extraAfterUnits;
      wants = [ "network-online.target" ];
    };
  };
}
