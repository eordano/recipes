# mesh-overlay-address-identity
#
# Keep a declarative "name -> overlay address" map honest against the live mesh,
# and repair the control plane when a node re-registers under a new address.
#
# Two tools, one problem:
#
#   * mesh-address-drift-check — a pre-commit reconciler. It compares the map
#     file in your repo against the live netmap, blocks on address reuse and on
#     re-registration duplicates, and auto-appends genuinely new devices above a
#     marker comment so the map cannot rot silently.
#
#   * mesh-node-reassociate — a repair tool for the coordination host. A control
#     plane that allocates addresses sequentially cannot hand a re-registering
#     node its old address back, so the only way to restore the canonical
#     address the rest of the fleet pins is a direct database edit. This wraps
#     that edit safely: stop, snapshot, single transaction, restart,
#     health-check, post-check, then nudge the node to re-poll.
#
# The map itself is an option here (`addresses`/`aliases`/`ignore`) so other
# modules can consume it, but the file of record lives in your repository: the
# pre-commit hook has to be able to append to it.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.networking.meshAddressIdentity;

  reassociate = pkgs.writeShellApplication {
    name = "mesh-node-reassociate";
    runtimeInputs = [
      pkgs.sqlite
      pkgs.openssh
    ];
    text = ''
      export MESH_CP_DB="''${MESH_CP_DB:-${cfg.reassociate.database}}"
      export MESH_CP_SERVICE="''${MESH_CP_SERVICE:-${cfg.reassociate.serviceName}}"
      export MESH_CP_CLI="''${MESH_CP_CLI:-${cfg.reassociate.cli}}"
      export MESH_NODE_RESTART="''${MESH_NODE_RESTART:-${cfg.reassociate.nodeRestartCommand}}"
      export MESH_ADDR_PREFIXES="''${MESH_ADDR_PREFIXES:-${lib.concatStringsSep "," cfg.addressPrefixes}}"
    ''
    + builtins.readFile ./mesh-node-reassociate.sh;
  };

  driftCheck = pkgs.writeShellApplication {
    name = "mesh-address-drift-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${./mesh-address-drift-check.py} \
        --map-glob ${lib.escapeShellArg cfg.driftCheck.mapGlob} \
        --key-addresses ${lib.escapeShellArg cfg.driftCheck.keys.addresses} \
        --key-aliases ${lib.escapeShellArg cfg.driftCheck.keys.aliases} \
        --key-ignore ${lib.escapeShellArg cfg.driftCheck.keys.ignore} \
        --marker ${lib.escapeShellArg cfg.driftCheck.marker} \
        --overlay-prefix ${lib.escapeShellArg cfg.driftCheck.overlayPrefix} \
        "$@"
    '';
  };

  hostNames = name: [ name ] ++ lib.optional (cfg.hostAliases.domain != null) "${name}.${cfg.hostAliases.domain}";

  # networking.hosts is keyed by address, the map by name; several names may
  # legitimately share one address, so merge rather than overwrite.
  byAddress = lib.foldlAttrs (
    acc: name: addr: acc // { ${addr} = (acc.${addr} or [ ]) ++ hostNames name; }
  ) { } cfg.addresses;

  duplicateAddresses = lib.filterAttrs (_: names: builtins.length names > 1) (
    lib.foldlAttrs (acc: name: addr: acc // { ${addr} = (acc.${addr} or [ ]) ++ [ name ]; }) { }
      cfg.addresses
  );
in
{
  options.networking.meshAddressIdentity = {
    addresses = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        {
          workstation = "100.100.100.10";
          builder = "100.100.100.11";
          gateway = "100.100.100.42";
        }
      '';
      description = ''
        Canonical map of machine name to overlay address: the single source of
        truth every consumer pins (host aliases, ACL host groups, ssh config,
        DNS servers on exit nodes). Normally set from the same repository file
        the drift checker maintains, e.g.
        `(import ../mesh-addresses.nix).addresses`.
      '';
    };

    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        builder = "build-box";
      };
      description = ''
        Canonical name -> the given-name the control plane actually serves,
        for machines whose live name intentionally differs (historical names,
        rename lag). The drift checker accepts either spelling; anything else
        is flagged.
      '';
    };

    ignore = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "100.100.100.90" ];
      description = ''
        Overlay addresses the drift checker ignores entirely — known-junk
        registrations (installer images, short-lived VMs) that are pending
        deletion on the coordination host.
      '';
    };

    addressPrefixes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "100.100." ];
      description = ''
        Address prefixes `mesh-node-reassociate --to-ip` will accept. Set this
        to the leading octets of your overlay range so a typo cannot point a
        node at a public address. Empty accepts any IPv4 address.
      '';
    };

    hostAliases = {
      enable = lib.mkEnableOption "/etc/hosts entries generated from the address map";

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "mesh.example.org";
        description = "When set, also emit `<name>.<domain>` for every entry.";
      };
    };

    reassociate = {
      enable = lib.mkEnableOption "the mesh-node-reassociate repair tool (install on the coordination host)";

      database = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/headscale/db.sqlite";
        description = ''
          Coordination server's sqlite database. Must have a `nodes` table with
          `id`, `given_name`, `ipv4` and `ipv6` columns; the tool refuses to run
          against any other schema.
        '';
      };

      serviceName = lib.mkOption {
        type = lib.types.str;
        default = "headscale";
        description = "systemd unit stopped for the duration of the database edit.";
      };

      cli = lib.mkOption {
        type = lib.types.str;
        default = "headscale";
        description = ''
          Command used to confirm the coordination server is healthy after the
          edit; it is invoked as `<cli> nodes list`.
        '';
      };

      nodeRestartCommand = lib.mkOption {
        type = lib.types.str;
        default = "systemctl restart tailscaled";
        description = ''
          Command run on the node (over `--node-ssh`) to force it to re-poll the
          control plane instead of waiting for its next netmap update.
        '';
      };
    };

    driftCheck = {
      enable = lib.mkEnableOption "the mesh-address-drift-check reconciler (install where you commit)";

      mapGlob = lib.mkOption {
        type = lib.types.str;
        default = "*mesh-addresses.nix";
        example = "*globals/overlay-addresses.nix";
        description = ''
          `git ls-files` pattern locating the map inside the repository being
          committed. Must match exactly one tracked file.
        '';
      };

      marker = lib.mkOption {
        type = lib.types.str;
        default = "drift-hook:";
        description = ''
          Marker comment in the map file. Auto-added entries are inserted on the
          line above it, so the marker must be the last line of the block that
          new devices belong in.
        '';
      };

      overlayPrefix = lib.mkOption {
        type = lib.types.str;
        default = "100.";
        description = ''
          Only addresses starting with this prefix are treated as overlay
          addresses when reading the live netmap.
        '';
      };

      keys = {
        addresses = lib.mkOption {
          type = lib.types.str;
          default = "addresses";
          description = "Attribute in the map file holding name -> address.";
        };
        aliases = lib.mkOption {
          type = lib.types.str;
          default = "aliases";
          description = "Attribute in the map file holding canonical -> live name.";
        };
        ignore = lib.mkOption {
          type = lib.types.str;
          default = "ignore";
          description = "Attribute in the map file holding addresses to ignore.";
        };
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = duplicateAddresses == { };
        message =
          "networking.meshAddressIdentity.addresses maps several names to one address: "
          + lib.concatStringsSep "; " (
            lib.mapAttrsToList (addr: names: "${addr} <- ${lib.concatStringsSep ", " names}") duplicateAddresses
          )
          + " — one address per machine, or the drift checker cannot tell reuse from a rename.";
      }
      {
        assertion = lib.all (n: cfg.addresses ? ${n}) (lib.attrNames cfg.aliases);
        message =
          "networking.meshAddressIdentity.aliases names machines absent from addresses: "
          + lib.concatStringsSep ", " (lib.filter (n: !(cfg.addresses ? ${n})) (lib.attrNames cfg.aliases));
      }
    ];

    networking.hosts = lib.mkIf cfg.hostAliases.enable byAddress;

    environment.systemPackages =
      lib.optional cfg.reassociate.enable reassociate ++ lib.optional cfg.driftCheck.enable driftCheck;
  };
}
