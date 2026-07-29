# ip-cidr-set-exclude
#
# Compute a minimal CIDR list as a set-difference (allow-networks minus
# deny-networks) at BUILD TIME. This is the clean way to derive WireGuard
# `AllowedIPs` for split-tunnel routing that must carve holes out of a broad
# route (e.g. route everything through the tunnel EXCEPT LAN / RFC1918 /
# a management subnet) without hand-maintaining the CIDR arithmetic.
#
# WireGuard's `AllowedIPs` has no "exclude" syntax: a hole in `0.0.0.0/0`
# can only be expressed as the complementary set of ranges that tile around
# it. Doing that by hand is error-prone; this does it deterministically.
#
# Two things are exported:
#   * `ip-mask`    — a CLI (`ip-mask <allow> <deny>`) for interactive use.
#   * `buildIpList allow deny` — a Nix function returning a `[ "cidr" ... ]`
#                    list you can splat straight into `AllowedIPs`.
#
# Usage as a plain helper:
#   let tools = import ./ip-cidr-set-exclude { inherit pkgs; };
#   in tools.buildIpList "0.0.0.0/0" "10.0.0.0/8,192.168.0.0/16,127.0.0.0/8"
#      # => [ "0.0.0.0/5" "8.0.0.0/7" ... ] (0/0 minus the private ranges)
#
# Usage as an overlay (put this whole dir on your overlay list and wrap):
#   final: prev: (import ./ip-cidr-set-exclude { pkgs = prev; })
#   # then `pkgs.ip-mask` and `pkgs.buildIpList` are available.
#
# Both allow/deny arguments accept either a comma-joined string
# ("0.0.0.0/0,::/0") or a Nix list of strings ([ "0.0.0.0/0" "::/0" ]).
# Bare addresses are widened to /32 (v4) or /128 (v6). IPv4 and IPv6 are
# handled independently and IPv4 ranges are emitted first.

{ pkgs }:

with builtins;

let
  # The set-subtraction itself lives in a small Python step: Python's
  # `ipaddress` module already knows how to split a network around an
  # excluded subnet (`address_exclude`), which is the fiddly part.
  ipMaskPy = pkgs.writeText "ip-mask.py" ''
    import ipaddress
    import sys


    def parse_ip_networks(ip_list_str):
        ip_list = ip_list_str.split(",")
        networks = []
        invalid_ip_addresses = []

        for ip in ip_list:
            ip = ip.strip()
            if not ip:
                continue
            try:
                if "/" in ip:
                    networks.append(ipaddress.ip_network(ip, strict=False))
                else:
                    ip_obj = ipaddress.ip_address(ip)
                    if ip_obj.version == 4:
                        networks.append(ipaddress.ip_network(f"{ip}/32", strict=False))
                    else:
                        networks.append(ipaddress.ip_network(f"{ip}/128", strict=False))
            except ValueError:
                invalid_ip_addresses.append(ip)

        return networks, invalid_ip_addresses


    def get_input_and_parse(prompt):
        while True:
            user_input = input(prompt)
            networks, invalid_ip_addresses = parse_ip_networks(user_input)

            if not invalid_ip_addresses:
                break

            print("Invalid IPs or subnets: " + ", ".join(invalid_ip_addresses))
            print("Please try again. Ctrl+C to exit.")

        return networks


    def exclude_networks(allowed_networks, disallowed_networks):
        remaining_networks = set(allowed_networks)

        for disallowed in disallowed_networks:
            new_remaining_networks = set()

            for allowed in remaining_networks:
                if allowed.version == disallowed.version:
                    if disallowed.subnet_of(allowed):
                        # disallowed sits inside allowed: split allowed around it
                        new_remaining_networks.update(allowed.address_exclude(disallowed))
                    elif allowed.overlaps(disallowed):
                        # partial overlap
                        new_remaining_networks.update(
                            handle_partial_overlap(allowed, disallowed)
                        )
                    else:
                        # no overlap: keep as-is
                        new_remaining_networks.add(allowed)
                else:
                    # different IP versions never overlap: keep as-is
                    new_remaining_networks.add(allowed)

            remaining_networks = new_remaining_networks

        return remaining_networks


    def handle_partial_overlap(allowed, disallowed):
        # Return the non-overlapping portion of `allowed`. This enumerates
        # host addresses, so keep partial overlaps small (do not straddle
        # a huge allowed range with a tiny deny range from a different block).
        non_overlapping_networks = []

        allowed_ips = list(allowed.hosts())
        disallowed_ips = set(disallowed.hosts())

        allowed_ips = [ip for ip in allowed_ips if ip not in disallowed_ips]

        if not allowed_ips:
            return non_overlapping_networks

        for ip in allowed_ips:
            if ip.version == 4:
                non_overlapping_networks.append(
                    ipaddress.ip_network(f"{ip}/32", strict=False)
                )
            else:
                non_overlapping_networks.append(
                    ipaddress.ip_network(f"{ip}/128", strict=False)
                )

        return non_overlapping_networks


    def sort_networks(networks):
        """All IPv4 first, then IPv6, each from lowest to highest."""
        ipv4 = []
        ipv6 = []
        for net in networks:
            if net.version == 4:
                ipv4.append(net)
            else:
                ipv6.append(net)
        ipv4_sorted = sorted(ipv4, key=lambda ip: ip.network_address)
        ipv6_sorted = sorted(ipv6, key=lambda ip: ip.network_address)

        return ipv4_sorted + ipv6_sorted


    def main(unittest=False):
        allowed_input = ""
        disallowed_input = ""
        allowed_networks = []
        disallowed_networks = []

        if len(sys.argv) == 3:
            allowed_input = sys.argv[1]
            disallowed_input = sys.argv[2]
        elif len(sys.argv) == 2:
            disallowed_input = sys.argv[1]
        else:
            print("Wrong number of arguments provided, falling back to interactive mode.")
            allowed_input = ""
            disallowed_input = ""

        if allowed_input:
            allowed_networks, invalid_allowed = parse_ip_networks(allowed_input)
            if invalid_allowed:
                print("Invalid Allowed IPs: " + ", ".join(invalid_allowed))
                allowed_networks = []

        if disallowed_input:
            disallowed_networks, invalid_disallowed = parse_ip_networks(disallowed_input)
            if invalid_disallowed:
                print("Invalid Disallowed IPs: " + ", ".join(invalid_disallowed))
                disallowed_networks = []

        if not allowed_networks and not len(sys.argv) == 2:
            allowed_networks = get_input_and_parse(
                "Enter the Allowed IPs, comma separated (e.g., 0.0.0.0/0):\n"
            )

        if not disallowed_networks:
            disallowed_networks = get_input_and_parse(
                "Enter the Disallowed IPs, comma separated "
                "(e.g., 10.0.0.0/8,127.0.0.0/8,172.16.0.0/12,192.168.0.0/16):\n"
            )

        excluded_allowed_networks = exclude_networks(allowed_networks, disallowed_networks)
        sorted_networks = sort_networks(excluded_allowed_networks)

        if not sorted_networks:
            print("Error: No IPs are allowed based on the provided input.")
            sys.exit(1)

        print(", ".join(map(str, sorted_networks)))

        if unittest:
            return sorted_networks


    if __name__ == "__main__":
        main()
  '';

  # Build-time subtraction: run the Python step in a derivation and capture
  # its single-line, comma-separated output.
  buildIp =
    allowList: denyList:
    pkgs.runCommand "wg-ip" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      ${pkgs.python3}/bin/python ${ipMaskPy} ${allowList} ${denyList} > $out
    '';

  # Accept either a Nix list of CIDRs or an already-comma-joined string.
  buildList = x: if typeOf x == "string" then x else concatStringsSep "," x;
in
{
  # CLI: `ip-mask <allow> <deny>` (or run with no args for interactive mode).
  ip-mask = pkgs.writeShellScriptBin "ip-mask" ''
    exec ${pkgs.python3}/bin/python3 ${ipMaskPy} "$@"
  '';

  # `buildIpList allow deny` -> [ "cidr" ... ], ready for AllowedIPs.
  #
  # Trap: the Python prints one trailing newline; strip it BEFORE splitting on
  # ", ", otherwise the final element carries a "\n" and WireGuard rejects it.
  buildIpList =
    allowList: denyList:
    let
      output = readFile (buildIp (buildList allowList) (buildList denyList));
      takeOutEndline = x: substring 0 ((stringLength x) - 1) x;
      sanitized = takeOutEndline output;
    in
    # `split` yields interleaved match groups (lists); keep only the strings.
    filter (x: (typeOf x == "string")) (split ", " sanitized);
}
