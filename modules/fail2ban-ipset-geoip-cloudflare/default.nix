# fail2ban-ipset-geoip-cloudflare
#
# Back fail2ban with kernel ipsets instead of one iptables rule per banned IP:
#
#   * f2b-banned     (hash:ip, timeout)  - the set jails add offenders to
#   * f2b-whitelist  (hash:net)          - trusted networks that can never be banned
#
# A single high-priority INPUT rule does the enforcement:
#
#   iptables -I INPUT 1 -m set --match-set f2b-banned src \
#                       -m set ! --match-set f2b-whitelist src -j REJECT
#
# Why this shape:
#   * O(1) match and tens of thousands of bans without a rule-per-IP explosion.
#   * The rule lives in networking.firewall.extraCommands, so it is re-created on
#     every firewall reload -- bans (held in the kernel ipset with per-entry
#     timeouts) survive `nixos-rebuild switch`, firewall restarts, and jail
#     reloads.
#   * The whitelist is an *override* baked into the same match ("banned AND NOT
#     whitelisted"), not a separate rule that could race the ban rule. A trusted
#     source is dropped from the ban path even if a jail matches it.
#   * Seed the whitelist from GeoIP country CIDRs + your reverse proxy / CDN edge
#     ranges. If you sit behind a CDN, the offender's real IP is masked behind the
#     edge; whitelisting the edge ranges stops fail2ban from banning the CDN
#     itself (which would blackhole *all* traffic). The optional Cloudflare API
#     action mirrors the ban to the edge, where the real client actually connects.
#
# Gotcha: ipset stores the timeout as a signed 32-bit int, so actionban caps
# <bantime> at 2147483s (~24.8 days). A larger bantime overflows and the `ipset
# add` fails -- the cap in the action file is load-bearing, keep it.
#
# This is a self-contained NixOS module. Import it and set
# `services.fail2banIpset.enable = true;`.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fail2banIpset;

  # Cloudflare (or any CDN/reverse-proxy) edge ranges to whitelist, read from a
  # plain file with one IP/CIDR per line (comments starting with '#' ignored).
  # e.g. the `lists/cloudflare_ips_raw.txt` from
  # https://github.com/jimaek/cloudflare-ip-ranges, vendored as a flake input,
  # or any file you generate. When cfg.edgeRangesFile is null this is empty.
  edgeRanges =
    if cfg.edgeRangesFile == null then
      [ ]
    else
      builtins.filter (l: l != "" && !(lib.hasPrefix "#" l)) (
        lib.splitString "\n" (lib.removeSuffix "\n" (builtins.readFile cfg.edgeRangesFile))
      );
  edgeIPv4 = builtins.filter (ip: !(lib.hasInfix ":" ip)) edgeRanges;
  edgeIPv6 = builtins.filter (ip: lib.hasInfix ":" ip) edgeRanges;

  hasGeoip = cfg.geoipCountrylistPackage != null;

  # nixpkgs' nftables-based firewall (firewall-nftables.nix) hard-asserts
  # networking.firewall.extraCommands/extraStopCommands == "" -- this module
  # can't drive its enforcing rule through them on that backend. Instead it
  # keeps its own nftables table (family inet, name fail2ban-ipset) OUTSIDE
  # `networking.nftables.tables`: that option's declared tables are deleted
  # and fully recreated on every nftables.service reload/restart (including
  # every `nixos-rebuild switch` that touches the ruleset), which would wipe
  # the live f2b-banned/f2b-whitelist elements -- exactly the
  # survives-reload guarantee this module exists to provide. A separate,
  # self-managed table with idempotent `nft add table/set` (create-if-
  # missing, unlike `nft create`, which errors) is unaffected by that
  # teardown and only touches its own enforcing chain.
  nft = config.networking.firewall.backend == "nftables";
  nftBin = "${pkgs.nftables}/bin/nft";

  # RFC1918 + loopback, ported from the ipset seed list below.
  nftBaseWhitelistV4 = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8";
  nftBaseWhitelistV6 = "::1/128, fe80::/10, fc00::/7";

  nftWhitelistGeoipCommands =
    family:
    lib.optionalString hasGeoip (
      lib.concatMapStrings (country: ''
        if [ -f "${cfg.geoipCountrylistPackage}/share/geoip-country-lists/${country}/${family}-aggregated.txt" ]; then
          ${pkgs.gnugrep}/bin/grep -v '^#' \
            "${cfg.geoipCountrylistPackage}/share/geoip-country-lists/${country}/${family}-aggregated.txt" \
            | while read -r cidr; do
                [ -n "$cidr" ] && $NFT add element inet fail2ban-ipset f2b-whitelist${
                  if family == "ipv6" then "6" else ""
                } "{ $cidr }"
              done
        fi
      '') cfg.whitelistCountries
    );

  # (Re)creates the table/sets/enforcing chain. Sets are only ever `add`ed
  # (idempotent, never flushed) except f2b-whitelist[6], which is fully
  # static/derived and safe to flush + rebuild every run. The enforcing
  # chain is deleted and re-added each run so `add rule` (which always
  # appends, never de-duplicates) can't pile up copies of the reject rule.
  nftSetupScript = pkgs.writeShellScript "fail2ban-ipset-nftables-setup" ''
    set -euo pipefail
    NFT=${nftBin}

    $NFT add table inet fail2ban-ipset
    $NFT add set inet fail2ban-ipset f2b-banned '{ type ipv4_addr; flags timeout; }'
    $NFT add set inet fail2ban-ipset f2b-whitelist '{ type ipv4_addr; flags interval; auto-merge; }'

    $NFT flush set inet fail2ban-ipset f2b-whitelist
    $NFT add element inet fail2ban-ipset f2b-whitelist "{ ${nftBaseWhitelistV4} }"

    ${nftWhitelistGeoipCommands "ipv4"}

    ${lib.concatMapStrings (ip: ''
      $NFT add element inet fail2ban-ipset f2b-whitelist "{ ${ip} }"
    '') edgeIPv4}

    ${lib.concatMapStrings (ip: ''
      $NFT add element inet fail2ban-ipset f2b-whitelist "{ ${ip} }"
    '') cfg.whitelistIPv4}

    $NFT delete chain inet fail2ban-ipset input 2>/dev/null || true
    $NFT add chain inet fail2ban-ipset input '{ type filter hook input priority filter - 10 ; }'
    $NFT add rule inet fail2ban-ipset input ip saddr @f2b-banned ip saddr != @f2b-whitelist reject with icmp type port-unreachable

    ${lib.optionalString config.networking.enableIPv6 ''
      $NFT add set inet fail2ban-ipset f2b-banned6 '{ type ipv6_addr; flags timeout; }'
      $NFT add set inet fail2ban-ipset f2b-whitelist6 '{ type ipv6_addr; flags interval; auto-merge; }'

      $NFT flush set inet fail2ban-ipset f2b-whitelist6
      $NFT add element inet fail2ban-ipset f2b-whitelist6 "{ ${nftBaseWhitelistV6} }"

      ${nftWhitelistGeoipCommands "ipv6"}

      ${lib.concatMapStrings (ip: ''
        $NFT add element inet fail2ban-ipset f2b-whitelist6 "{ ${ip} }"
      '') edgeIPv6}

      ${lib.concatMapStrings (ip: ''
        $NFT add element inet fail2ban-ipset f2b-whitelist6 "{ ${ip} }"
      '') cfg.whitelistIPv6}

      $NFT add rule inet fail2ban-ipset input ip6 saddr @f2b-banned6 ip6 saddr != @f2b-whitelist6 reject with icmpv6 type port-unreachable
    ''}
  '';

  # Removes only the enforcing chain/rule, exactly like extraStopCommands
  # does for the iptables rule -- the bans and whitelist sets are untouched.
  nftTeardownScript = pkgs.writeShellScript "fail2ban-ipset-nftables-teardown" ''
    ${nftBin} delete chain inet fail2ban-ipset input 2>/dev/null || true
  '';

  # nginx access-log patterns that mark obvious probes/scanners. Generic and
  # provider-neutral; tune to taste.
  nginxRules = builtins.concatStringsSep "|" [
    ''"GET /(\.|config|admin|backup|private|secret|\.env|\.well-known/matrix/server).* HTTP/.*" 404''
    ''"GET /cgi-bin/.*;.*\?form=.*&.*=.* HTTP/.*" 4[0-9]{2}''
    ''"POST /.* HTTP/.*" 4[0-9]{2}''
    ''"(POST|GET) /.*(ViewLog|admin|login|cgi-bin|boaform|cdn-cgi/trace).* HTTP/.*" 4[0-9]{2}''
    ''".*x.*" 400''
    ''"GET / HTTP/.*" [0-9]{3} ("Mozilla/5.0 zgrab/|"Expanse, a Palo Alto Networks company|"Mozilla/5.0 \(compatible; CensysInspect/).*"''
    ''"GET /.*\.(php|asp|aspx|jsp|cgi) HTTP/.*" [0-9]{3}''
  ];
in
{
  options.services.fail2banIpset = {
    enable = lib.mkEnableOption "ipset-backed fail2ban with GeoIP + edge-range whitelisting";

    whitelistCountries = lib.mkOption {
      description = ''
        Country codes (lowercase, e.g. "de") whose aggregated CIDR ranges are
        added to the f2b-whitelist ipset at firewall startup, keeping entire
        trusted regions out of the ban path. Requires `geoipCountrylistPackage`
        to be set; ignored otherwise.
      '';
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "de" "at" ];
    };

    geoipCountrylistPackage = lib.mkOption {
      description = ''
        A package that provides per-country aggregated prefix lists at
          <pkg>/share/geoip-country-lists/<cc>/ipv4-aggregated.txt
          <pkg>/share/geoip-country-lists/<cc>/ipv6-aggregated.txt
        (one CIDR per line, '#' comments allowed). Set null to disable
        country-based whitelisting. There is no such package in nixpkgs by
        default -- supply your own overlay/derivation built from e.g. the
        herrbischoff/country-ip-blocks or ipverse aggregated lists.
      '';
      type = lib.types.nullOr lib.types.package;
      default = null;
    };

    whitelistIPv4 = lib.mkOption {
      description = ''
        Extra IPv4 addresses/CIDRs to add to the f2b-whitelist ipset and to
        fail2ban's ignoreIP. Put your own reverse proxy, monitoring hosts, and
        management ranges here so they can never be banned.
      '';
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "198.51.100.10" "203.0.113.0/24" ];
    };

    whitelistIPv6 = lib.mkOption {
      description = "Extra IPv6 addresses/CIDRs to add to the f2b-whitelist6 ipset and ignoreIP.";
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "2001:db8::1" ];
    };

    edgeRangesFile = lib.mkOption {
      description = ''
        Path to a file listing your CDN / reverse-proxy edge ranges, one IP or
        CIDR per line ('#' comments ignored, IPv4 and IPv6 mixed is fine). These
        are whitelisted so the edge itself is never banned when it fronts your
        traffic (banning it would blackhole every visitor). Set null if you have
        no fronting edge.
      '';
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    banTime = lib.mkOption {
      description = "Default jail bantime. Note the ipset timeout is separately capped at ~24.8 days.";
      type = lib.types.str;
      default = "96h";
    };

    nginx = {
      enable = lib.mkOption {
        description = "Enable the nginx access-log probe/scanner jail.";
        type = lib.types.bool;
        default = config.services.nginx.enable or false;
        defaultText = lib.literalExpression "config.services.nginx.enable";
      };
      logPath = lib.mkOption {
        description = "nginx access log the nginx-protect jail reads.";
        type = lib.types.str;
        default = "/var/log/nginx/access.log";
      };
    };

    kernelJail.enable = lib.mkOption {
      description = ''
        Enable the kernel-sus-connections jail: bans hosts the kernel logs as
        "refused connection" (needs firewall connection logging enabled).
      '';
      type = lib.types.bool;
      default = true;
    };

    cloudflare = {
      enable = lib.mkOption {
        description = ''
          Mirror bans to the Cloudflare edge via the API v4 IP access-rules
          endpoint. Useful when clients reach you through Cloudflare and their
          real IP is masked from the local firewall.
        '';
        type = lib.types.bool;
        default = false;
      };
      apiKeyFile = lib.mkOption {
        description = ''
          Runtime path to a file containing a Cloudflare API token (Bearer)
          with firewall access-rules edit scope. Provide this via a secret
          manager (agenix/sops/etc.) as a *string* path such as
          "/run/secrets/cloudflare-fail2ban-token". Never point it at a Nix
          path literal (e.g. ./cf-token): that copies the live token verbatim
          into the world-readable /nix/store. The type is `str` (not `path`)
          specifically to reject accidental path literals.
        '';
        type = lib.types.str;
        example = "/run/secrets/cloudflare-fail2ban-token";
      };
      email = lib.mkOption {
        description = "Account email exported as FAIL2BAN_CFUSER (some tooling expects it; the token is what authenticates).";
        type = lib.types.str;
        default = "noreply@example.com";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.whitelistCountries == [ ] || hasGeoip;
        message = ''
          services.fail2banIpset.whitelistCountries is set but
          geoipCountrylistPackage is null -- country whitelisting would be
          silently skipped. Set geoipCountrylistPackage, or clear
          whitelistCountries.
        '';
      }
    ];

    systemd.services.fail2ban = {
      after = [ "fail2ban-ipset-nftables.service" ] ++ lib.optional config.services.nginx.enable "nginx.service";
      wants = lib.mkIf config.services.nginx.enable [ "nginx.service" ];
      serviceConfig = lib.mkIf cfg.cloudflare.enable {
        Environment = [
          "FAIL2BAN_CFUSER=${cfg.cloudflare.email}"
        ];
      };
    };

    # Self-managed nftables table -- see the `nft`/nftSetupScript comment
    # above for why this isn't done via networking.nftables.tables.
    systemd.services.fail2ban-ipset-nftables = lib.mkIf nft {
      description = "fail2ban-ipset nftables table (f2b-banned/whitelist sets + enforcing reject rule)";
      after = [ "network-pre.target" ];
      wants = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${nftSetupScript}";
        ExecStop = "${nftTeardownScript}";
      };
    };

    boot.kernelModules = lib.optionals (!nft) [
      "iptable_nat"
      "iptable_filter"
      "xt_nat"
      "xt_mark"
      "xt_comment"
      "xt_multiport"
      "xt_set"
    ];
    environment.systemPackages = lib.optional (!nft) pkgs.ipset ++ lib.optional nft pkgs.nftables;

    # The ban/whitelist ipsets and the single enforcing INPUT rule are (re)built
    # here so they survive every firewall reload. (iptables backend only --
    # the nftables backend uses the fail2ban-ipset-nftables unit above.)
    networking.firewall.extraCommands = lib.optionalString (!nft) ''
      ${pkgs.ipset}/bin/ipset create -exist f2b-banned hash:ip timeout 345600 maxelem 65536

      ${pkgs.ipset}/bin/ipset create -exist f2b-whitelist hash:net maxelem 65536

      ${pkgs.ipset}/bin/ipset flush f2b-whitelist

      ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist 10.0.0.0/8
      ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist 172.16.0.0/12
      ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist 192.168.0.0/16
      ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist 127.0.0.0/8

      ${lib.optionalString hasGeoip (lib.concatMapStrings (country: ''
        if [ -f "${cfg.geoipCountrylistPackage}/share/geoip-country-lists/${country}/ipv4-aggregated.txt" ]; then
          ${pkgs.gnugrep}/bin/grep -v '^#' \
            "${cfg.geoipCountrylistPackage}/share/geoip-country-lists/${country}/ipv4-aggregated.txt" \
            | while read -r cidr; do
                [ -n "$cidr" ] && ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist "$cidr"
              done
        fi
      '') cfg.whitelistCountries)}

      ${lib.concatMapStrings (ip: ''
        ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist ${ip}
      '') edgeIPv4}

      ${lib.concatMapStrings (ip: ''
        ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist ${ip}
      '') cfg.whitelistIPv4}

      ${pkgs.iptables}/bin/iptables -D INPUT -m set --match-set f2b-banned src -m set ! --match-set f2b-whitelist src -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
      ${pkgs.iptables}/bin/iptables -I INPUT 1 -m set --match-set f2b-banned src -m set ! --match-set f2b-whitelist src -j REJECT --reject-with icmp-port-unreachable

      ${lib.optionalString config.networking.enableIPv6 ''
        ${pkgs.ipset}/bin/ipset create -exist f2b-banned6 hash:ip timeout 345600 family inet6 maxelem 65536
        ${pkgs.ipset}/bin/ipset create -exist f2b-whitelist6 hash:net family inet6 maxelem 65536

        ${pkgs.ipset}/bin/ipset flush f2b-whitelist6
        ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist6 ::1/128
        ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist6 fe80::/10
        ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist6 fc00::/7

        ${lib.optionalString hasGeoip (lib.concatMapStrings (country: ''
          if [ -f "${cfg.geoipCountrylistPackage}/share/geoip-country-lists/${country}/ipv6-aggregated.txt" ]; then
            ${pkgs.gnugrep}/bin/grep -v '^#' \
              "${cfg.geoipCountrylistPackage}/share/geoip-country-lists/${country}/ipv6-aggregated.txt" \
              | while read -r cidr; do
                  [ -n "$cidr" ] && ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist6 "$cidr"
                done
          fi
        '') cfg.whitelistCountries)}

        ${lib.concatMapStrings (ip: ''
          ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist6 ${ip}
        '') edgeIPv6}

        ${lib.concatMapStrings (ip: ''
          ${pkgs.ipset}/bin/ipset add -exist f2b-whitelist6 ${ip}
        '') cfg.whitelistIPv6}

        ${pkgs.iptables}/bin/ip6tables -D INPUT -m set --match-set f2b-banned6 src -m set ! --match-set f2b-whitelist6 src -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || true
        ${pkgs.iptables}/bin/ip6tables -I INPUT 1 -m set --match-set f2b-banned6 src -m set ! --match-set f2b-whitelist6 src -j REJECT --reject-with icmp6-port-unreachable
      ''}
    '';

    networking.firewall.extraStopCommands = lib.optionalString (!nft) ''
      ${pkgs.iptables}/bin/iptables -D INPUT -m set --match-set f2b-banned src -m set ! --match-set f2b-whitelist src -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true

      ${lib.optionalString config.networking.enableIPv6 ''
        ${pkgs.iptables}/bin/ip6tables -D INPUT -m set --match-set f2b-banned6 src -m set ! --match-set f2b-whitelist6 src -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || true
      ''}
    '';

    services.fail2ban = {
      enable = true;
      ignoreIP = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "127.0.0.0/8"
        "localhost"
      ]
      ++ cfg.whitelistIPv4
      ++ edgeIPv4
      ++ lib.optionals config.networking.enableIPv6 cfg.whitelistIPv6
      ++ lib.optionals config.networking.enableIPv6 edgeIPv6;
      banaction = "custom-ipset";
      banaction-allports = "custom-ipset";
      bantime = cfg.banTime;
      bantime-increment = {
        enable = true;
        formula = "ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)";
        overalljails = true;
      };
      jails = {
        DEFAULT.settings = {
          loglevel = "WARNING";
        };
        kernel-sus-connections.settings = lib.mkIf cfg.kernelJail.enable {
          enabled = true;
          filter = "kernel-sus-connections";
          backend = "systemd";
          maxretry = 3;
          findtime = 3600;
          bantime = "168h";
          action = "custom-ipset";
        };
        nginx-protect.settings = lib.mkIf cfg.nginx.enable {
          enabled = true;
          filter = "nginx-protect";
          logpath = cfg.nginx.logPath;
          backend = "auto";
          maxretry = 3;
          findtime = 3600;
          bantime = "168h";
          action =
            if cfg.cloudflare.enable then
              ''
                custom-ipset[name=%(__name__)s]
                                    cloudflare''
            else
              "custom-ipset";
        };
      };
    };

    environment.etc = {
      # actionban caps <bantime> at 2147483s. That cap is specifically an
      # ipset signed-int32-timeout limit; nftables' set-element timeout is
      # not known to have the same ceiling, but since it's never been
      # verified against a real kernel in this environment, the nftables
      # actions below keep the identical cap out of caution rather than
      # assume a wider one is safe.
      "fail2ban/action.d/custom-ipset.conf".text =
        if nft then
          ''
            [Definition]
            actionstart =
            actionstop =
            actioncheck =

            actionban = TIMEOUT=<bantime>; \
                       [ "$TIMEOUT" -gt 2147483 ] && TIMEOUT=2147483; \
                       ${nftBin} add element inet fail2ban-ipset f2b-banned "{ <ip> timeout ''${TIMEOUT}s }" || \
                       (echo "Failed to ban <ip> in nftables set f2b-banned" >&2; exit 1)
            actionunban = ${nftBin} delete element inet fail2ban-ipset f2b-banned "{ <ip> }" || \
                         (echo "Failed to unban <ip> from nftables set f2b-banned (may already be unbanned)" >&2)

            [Init]
            bantime = 345600
          ''
        else
          ''

            [INCLUDES]
            before = iptables-common.conf

            [Definition]
            actionstart =
            actionstop =
            actioncheck =

            actionban = TIMEOUT=<bantime>; \
                       [ "$TIMEOUT" -gt 2147483 ] && TIMEOUT=2147483; \
                       ${pkgs.ipset}/bin/ipset -exist add f2b-banned <ip> timeout $TIMEOUT || \
                       (echo "Failed to ban <ip> in ipset f2b-banned" >&2; exit 1)
            actionunban = ${pkgs.ipset}/bin/ipset -exist del f2b-banned <ip> || \
                         (echo "Failed to unban <ip> from ipset f2b-banned (may already be unbanned)" >&2)

            [Init]
            bantime = 345600
          '';

      "fail2ban/action.d/custom-ipset6.conf".text =
        if nft then
          ''
            [Definition]
            actionstart =
            actionstop =
            actioncheck =

            actionban = TIMEOUT=<bantime>; \
                       [ "$TIMEOUT" -gt 2147483 ] && TIMEOUT=2147483; \
                       ${nftBin} add element inet fail2ban-ipset f2b-banned6 "{ <ip> timeout ''${TIMEOUT}s }" || \
                       (echo "Failed to ban <ip> in nftables set f2b-banned6" >&2; exit 1)
            actionunban = ${nftBin} delete element inet fail2ban-ipset f2b-banned6 "{ <ip> }" || \
                         (echo "Failed to unban <ip> from nftables set f2b-banned6 (may already be unbanned)" >&2)

            [Init]
            bantime = 345600
          ''
        else
          ''

            [INCLUDES]
            before = iptables-common.conf

            [Definition]
            actionstart =
            actionstop =
            actioncheck =

            actionban = TIMEOUT=<bantime>; \
                       [ "$TIMEOUT" -gt 2147483 ] && TIMEOUT=2147483; \
                       ${pkgs.ipset}/bin/ipset -exist add f2b-banned6 <ip> timeout $TIMEOUT || \
                       (echo "Failed to ban <ip> in ipset f2b-banned6" >&2; exit 1)
            actionunban = ${pkgs.ipset}/bin/ipset -exist del f2b-banned6 <ip> || \
                         (echo "Failed to unban <ip> from ipset f2b-banned6 (may already be unbanned)" >&2)

            [Init]
            bantime = 345600
          '';

      "fail2ban/filter.d/kernel-sus-connections.local".text = lib.mkDefault (
        lib.mkAfter ''
          [Definition]
          failregex = ^.*refused connection: .* SRC=<HOST> .*$
          journalmatch = _TRANSPORT=kernel
        ''
      );

      "fail2ban/filter.d/nginx-protect.local".text = lib.mkDefault (
        lib.mkAfter ''
          [Definition]
          failregex = <HOST> - - \[.*\] (${nginxRules})
        ''
      );
    }
    // lib.optionalAttrs cfg.cloudflare.enable {
      "fail2ban/action.d/cloudflare.local".text = ''
        [Definition]
        actionstart = echo "Cloudflare action started for <name>" | ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p info
        actionstop = echo "Cloudflare action stopped for <name>" | ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p info
        actioncheck =
        actionban = ${pkgs.bash}/bin/bash -c ' \
          API_KEY=$(cat ${cfg.cloudflare.apiKeyFile} | tr -d "\n\r ") && \
          ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p info \
            echo "Attempting to ban <ip> via Cloudflare API" && \
          RESPONSE=$(${pkgs.curl}/bin/curl -s -w "\nHTTP_CODE:%%{http_code}" \
            -X POST "https://api.cloudflare.com/client/v4/user/firewall/access_rules/rules" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            --data "{\"mode\":\"block\",\"configuration\":{\"target\":\"ip\",\"value\":\"<ip>\"},\"notes\":\"Fail2ban (<name>)\"}" \
            2>&1) && \
          HTTP_CODE=$(echo "$RESPONSE" | tail -n1 | cut -d: -f2) && \
          BODY=$(echo "$RESPONSE" | sed "$d") && \
          if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then \
            ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p info \
              echo "Successfully banned <ip> via Cloudflare"; \
          elif [ "$HTTP_CODE" = "400" ] && echo "$BODY" | grep -q "duplicate_of_existing"; then \
            ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p warning \
              echo "IP <ip> already banned in Cloudflare - skipping"; \
          else \
            ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p err \
              echo "Failed to ban <ip> - HTTP $HTTP_CODE - Response: $BODY"; \
            exit 1; \
          fi'
        actionunban = ${pkgs.bash}/bin/bash -c ' \
          API_KEY=$(cat ${cfg.cloudflare.apiKeyFile} | tr -d "\n\r ") && \
          ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p info \
            echo "Attempting to unban <ip> via Cloudflare API" && \
          RULE_ID=$(${pkgs.curl}/bin/curl -s \
            -X GET "https://api.cloudflare.com/client/v4/user/firewall/access_rules/rules?mode=block&configuration.target=ip&configuration.value=<ip>&page=1&per_page=1" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" | \
            ${pkgs.jq}/bin/jq -r ".result[0].id // empty") && \
          if [ -n "$RULE_ID" ]; then \
            RESPONSE=$(${pkgs.curl}/bin/curl -s -w "\nHTTP_CODE:%%{http_code}" \
              -X DELETE "https://api.cloudflare.com/client/v4/user/firewall/access_rules/rules/$RULE_ID" \
              -H "Authorization: Bearer $API_KEY" \
              -H "Content-Type: application/json" 2>&1) && \
            HTTP_CODE=$(echo "$RESPONSE" | tail -n1 | cut -d: -f2) && \
            if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then \
              ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p info \
                echo "Successfully unbanned <ip> from Cloudflare"; \
            else \
              BODY=$(echo "$RESPONSE" | sed "$d") && \
              ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p err \
                echo "Failed to unban <ip> - HTTP $HTTP_CODE - Response: $BODY"; \
              exit 1; \
            fi \
          else \
            ${pkgs.systemd}/bin/systemd-cat -t fail2ban-cloudflare -p warning \
              echo "No Cloudflare rule found for <ip> - possibly already unbanned"; \
          fi'
      '';
    };
  };
}
