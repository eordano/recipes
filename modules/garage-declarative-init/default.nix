# garage-declarative-init
#
# Wrap upstream `services.garage` so the cluster layout, buckets, and access
# keys are *declared in Nix* and reconciled idempotently on every boot, instead
# of the imperative one-time CLI steps upstream leaves you with.
#
# Import this file as a NixOS module and configure `services.garage-manager`.
# It is self-contained: no external cluster registry, no site-specific paths.
# Parameterize everything site-specific through the options below.

{
  config,
  pkgs,
  lib,
  ...
}:
with lib;
let
  cfg = config.services.garage-manager;

  domain = cfg.domain;
  rpcPort = cfg.ports.rpc;
  s3ApiPort = cfg.ports.s3Api;
  s3WebPort = cfg.ports.s3Web;
  adminPort = cfg.ports.admin;
  dataDir = cfg.dataDir;
  metadataDir = "${dirOf dataDir}/meta";

  isMultiNode = cfg.replicationFactor > 1;

  # Systemd mount units the data/metadata dirs live under (e.g. a ZFS dataset
  # mount unit like "tank-archive.mount"). Empty for a plain local dir.
  mountUnits = cfg.requiresMounts;
in
{
  options.services.garage-manager = {
    enable = mkEnableOption "Garage S3-compatible object storage service with declarative init";

    package = mkOption {
      type = types.package;
      default = pkgs.garage;
      defaultText = literalExpression "pkgs.garage";
      description = ''
        Garage package to use. The init script parses `garage layout` output, so
        pin a version whose CLI output matches (developed against Garage v2, e.g.
        `pkgs.garage_2`).
      '';
    };

    user = mkOption {
      type = types.str;
      default = "garage";
      description = "System user the daemon runs as. Kept stable on-disk (see DynamicUser trap).";
    };

    group = mkOption {
      type = types.str;
      default = "garage";
      description = "System group the daemon runs as.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/garage/data";
      description = ''
        Directory for Garage data storage. Metadata is placed in a sibling
        `meta` directory (`''${dirOf dataDir}/meta`). If this lives on a mount
        that is not present at early boot (e.g. a ZFS dataset), list its mount
        unit in `requiresMounts` so the daemon waits for it.
      '';
    };

    requiresMounts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "mnt-pool.mount" ];
      description = ''
        Systemd .mount units that must be active before the directories are
        created and the daemon starts. Use this when `dataDir` sits on a
        late-mounted filesystem (ZFS, NFS, LUKS) — without it the daemon can
        start against an empty pre-mount directory and lay down state on the
        wrong filesystem.
      '';
    };

    domain = mkOption {
      type = types.str;
      default = "example.com";
      description = ''
        Base domain for the public S3 + web endpoints. Only used when
        `exposeNginx = true`. Vhosts are `s3.garage.<domain>` and
        `*.web.garage.<domain>`.
      '';
    };

    replicationFactor = mkOption {
      type = types.int;
      default = 1;
      description = "Garage replication factor. > 1 enables multi-node mode (see nodeAddress/bootstrapPeers).";
    };

    nodeAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.0.0.5";
      description = ''
        This node's RPC-reachable address (bind + public). Required in
        multi-node mode (`replicationFactor > 1`); peers connect here. In
        single-node mode RPC binds to loopback and this is ignored.
      '';
    };

    bootstrapPeers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "10.0.0.6:3901" "10.0.0.7:3901" ];
      description = ''
        `host:port` addresses of the other cluster nodes to bootstrap RPC
        discovery from. Only used in multi-node mode.
      '';
    };

    zone = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = literalExpression "config.networking.hostName";
      description = "Garage layout zone this node is assigned to (used for replica placement).";
    };

    capacity = mkOption {
      type = types.str;
      default = "1G";
      example = "100G";
      description = "Storage capacity advertised to the Garage layout for this node.";
    };

    rpcSecretFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the shared RPC secret (a 32-byte hex string).
        Point this at whatever secret manager you use (agenix, sops-nix, a
        deploy-time file, …). All nodes in a cluster must share the same value.
      '';
    };

    adminTokenFile = mkOption {
      type = types.path;
      description = "Path to a file containing the admin API bearer token.";
    };

    ports = mkOption {
      type = types.submodule {
        options = {
          rpc = mkOption {
            type = types.port;
            default = 3901;
            description = "RPC port for internal communication";
          };
          s3Api = mkOption {
            type = types.port;
            default = 3900;
            description = "S3 API port";
          };
          s3Web = mkOption {
            type = types.port;
            default = 3902;
            description = "S3 web hosting port";
          };
          admin = mkOption {
            type = types.port;
            default = 3903;
            description = "Admin API port";
          };
        };
      };
      default = { };
      description = "Port configuration for Garage services";
    };

    trustedInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wg0";
      description = ''
        Network interface on which to open the RPC and admin ports (e.g. a VPN /
        WireGuard / Tailscale interface). The S3 API and web ports are never
        firewalled open — they are reached only through the nginx vhosts. Leave
        null for a single-node deployment that needs no inter-node RPC.
      '';
    };

    ensureBuckets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Buckets to ensure exist. Created on boot if missing, skipped if present.";
    };

    ensureAccess = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            key = mkOption {
              type = types.str;
              description = "Human-readable name for the key";
            };
            bucket = mkOption {
              type = types.str;
              description = "The bucket to grant access to";
            };
            accessKeyFile = mkOption {
              type = types.path;
              description = "Path to file containing the access key ID";
            };
            secretKeyFile = mkOption {
              type = types.path;
              description = "Path to file containing the secret key";
            };
            permissions = mkOption {
              type = types.listOf (
                types.enum [
                  "read"
                  "write"
                  "owner"
                ]
              );
              default = [
                "read"
                "write"
              ];
              description = "Permissions to grant";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Access keys to ensure exist, imported from files, and granted the given
        permissions on a bucket. Idempotent: existing keys are detected by ID and
        not re-imported.
      '';
    };

    logLevel = mkOption {
      type = types.enum [
        "trace"
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "warn";
      description = "Log level for the Garage service";
    };

    exposeNginx = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Publish the public S3 + web nginx vhosts (`s3.garage.<domain>`,
        `*.web.garage.<domain>`), which require an ACME cert for `<domain>`. Set
        false for an internal-only node (e.g. a replication-only cluster member)
        that joins the cluster but doesn't serve the public endpoint.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !isMultiNode || cfg.nodeAddress != null;
        message = "services.garage-manager: nodeAddress must be set when replicationFactor > 1.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "Garage storage daemon user";
    };
    users.groups.${cfg.group} = { };

    services.garage = {
      enable = true;
      package = cfg.package;

      settings = {
        replication_factor = cfg.replicationFactor;
        consistency_mode = "consistent";

        rpc_bind_addr =
          if isMultiNode then
            "${cfg.nodeAddress}:${toString rpcPort}"
          else
            # Single-node: bind RPC to loopback only. nginx never fronts RPC and
            # no peer connects, so all-interfaces exposure ([::]) is unwanted.
            "127.0.0.1:${toString rpcPort}";
        rpc_public_addr =
          if isMultiNode then "${cfg.nodeAddress}:${toString rpcPort}" else "127.0.0.1:${toString rpcPort}";
        rpc_secret_file = cfg.rpcSecretFile;
        bootstrap_peers = mkIf isMultiNode cfg.bootstrapPeers;

        metadata_dir = metadataDir;
        data_dir = dataDir;

        s3_api = {
          s3_region = "garage";
          # Loopback only: nginx proxies to 127.0.0.1, so binding to all
          # interfaces ([::]) would expose the unfronted S3 API directly.
          api_bind_addr = "127.0.0.1:${toString s3ApiPort}";
          root_domain = ".s3.garage.${domain}";
        };

        s3_web = {
          # Loopback only; reached through the nginx web vhost (127.0.0.1).
          bind_addr = "127.0.0.1:${toString s3WebPort}";
          root_domain = ".web.garage.${domain}";
        };

        admin = {
          api_bind_addr = "127.0.0.1:${toString adminPort}";
          admin_token_file = cfg.adminTokenFile;
        };

        log_level = cfg.logLevel;
      };
    };

    systemd = {
      tmpfiles.rules = [
        "d ${dataDir} 0700 ${cfg.user} ${cfg.group} - -"
        "d ${metadataDir} 0700 ${cfg.user} ${cfg.group} - -"
      ];
      services = {
        # Create + chown the data/metadata dirs AFTER their mount is up, BEFORE
        # the daemon starts. This is the ordering that keeps state on the right
        # filesystem with the right owner.
        garage-setup-dirs = {
          description = "Create Garage storage directories";
          after = mountUnits;
          requires = mountUnits;
          before = [ "garage.service" ];
          wantedBy = [ "garage.service" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "garage-setup-dirs" ''
              ${pkgs.coreutils}/bin/mkdir -p ${dataDir}
              ${pkgs.coreutils}/bin/mkdir -p ${metadataDir}
              ${pkgs.coreutils}/bin/chown ${cfg.user}:${cfg.group} ${dataDir}
              ${pkgs.coreutils}/bin/chown ${cfg.user}:${cfg.group} ${metadataDir}
              ${pkgs.coreutils}/bin/chmod 700 ${dataDir}
              ${pkgs.coreutils}/bin/chmod 700 ${metadataDir}
            '';
          };
        };

        garage = {
          after = mountUnits ++ [ "garage-setup-dirs.service" ];
          wants = mountUnits;
          requires = [ "garage-setup-dirs.service" ];
          serviceConfig = {
            User = cfg.user;
            Group = cfg.group;
            # TRAP: upstream's garage unit uses DynamicUser, which allocates a
            # fresh uid per activation. On a persistent data mount that leaves
            # on-disk files owned by a uid the next generation no longer maps to.
            # Force it off so the uid stays stable across restarts/rebuilds.
            DynamicUser = lib.mkForce false;
          };
        };

        # Idempotent, state-driven reconciler. Runs on every boot; picks the
        # right action from the current layout state and skips anything already
        # present.
        garage-init = {
          description = "Initialize Garage layout and create buckets";
          after = [ "garage.service" ];
          requires = [ "garage.service" ];
          wantedBy = [ "multi-user.target" ];

          path = [
            cfg.package
            pkgs.jq
            pkgs.coreutils
          ];

          script = ''
            set -e

            if ! garage status 2>/dev/null; then
              echo "ERROR: Garage service is not running or not ready"
              exit 1
            fi

            LAYOUT_STATUS=$(garage layout show 2>&1 || true)

            SELF_ID=$(garage node id -q 2>/dev/null | cut -d@ -f1 | cut -c1-16 || true)

            if echo "$LAYOUT_STATUS" | grep -q "No nodes currently have a role"; then
              ${
                if isMultiNode then
                  ''
                    # An empty layout here does NOT mean the cluster is fresh — it is
                    # what a node sees before it has met its peers. Assigning
                    # ourselves would fork a second single-node cluster, and applying
                    # it can never succeed because one node cannot satisfy
                    # replication_factor ${toString cfg.replicationFactor}. Leave the
                    # layout alone and let the peers arrive; bootstrapping a genuinely
                    # new multi-node cluster is a deliberate operator action.
                    echo "No layout yet and no peers visible; not bootstrapping (replication factor ${toString cfg.replicationFactor})."
                    exit 0
                  ''
                else
                  ''
                    # Single-node deployment: this really is a fresh cluster.
                    NODE_ID=$(garage status | grep -oE '^[a-f0-9]{16}' | head -1)

                    if [ -n "$NODE_ID" ]; then
                      echo "Setting up single-node layout for node: $NODE_ID (zone ${cfg.zone})"
                      garage layout assign -z ${cfg.zone} -c ${cfg.capacity} "$NODE_ID"

                      CURRENT_VERSION=$(garage layout show | grep -oP 'Current cluster layout version: \K\d+' || echo "0")
                      NEW_VERSION=$((CURRENT_VERSION + 1))
                      echo "Applying layout version $NEW_VERSION"
                      garage layout apply --version "$NEW_VERSION"
                    fi
                  ''
              }
            elif echo "$LAYOUT_STATUS" | grep -q "Role changes are staged but not yet committed"; then
              # Staged-but-uncommitted: just commit.
              echo "Found staged layout changes, applying..."
              CURRENT_VERSION=$(garage layout show | grep -oP 'Current cluster layout version: \K\d+' || echo "0")
              NEW_VERSION=$((CURRENT_VERSION + 1))
              echo "Applying staged changes with version $NEW_VERSION"
              garage layout apply --version "$NEW_VERSION"
            elif [ -n "$SELF_ID" ] && ! echo "$LAYOUT_STATUS" | grep -q "$SELF_ID"; then
              # Existing cluster we haven't joined: assign self, then commit.
              echo "Joining existing cluster: assigning role to $SELF_ID (zone ${cfg.zone})"
              garage layout assign -z ${cfg.zone} -c ${cfg.capacity} "$SELF_ID"
              CURRENT_VERSION=$(garage layout show | grep -oP 'Current cluster layout version: \K\d+' || echo "0")
              NEW_VERSION=$((CURRENT_VERSION + 1))
              echo "Applying layout version $NEW_VERSION"
              garage layout apply --version "$NEW_VERSION"
            else
              echo "Layout already configured, skipping..."
            fi

            ${concatMapStrings (bucket: ''
              echo "Checking bucket: ${bucket}"
              if garage bucket info ${bucket} >/dev/null 2>&1; then
                echo "Bucket ${bucket} already exists, skipping..."
              else
                echo "Creating bucket: ${bucket}"
                garage bucket create ${bucket} || {
                  echo "Failed to create bucket ${bucket}, it may already exist"
                }
              fi
            '') cfg.ensureBuckets}

            ${concatMapStrings (access: ''
              echo "Configuring access for key: ${access.key}"

              ACCESS_KEY=$(cat ${access.accessKeyFile})
              SECRET_KEY=$(cat ${access.secretKeyFile})

              if garage key info "$ACCESS_KEY" >/dev/null 2>&1; then
                echo "Key ${access.key} already exists with ID $ACCESS_KEY"
              else
                echo "Importing key ${access.key} with ID $ACCESS_KEY"
                garage key import --yes --name "${access.key}" "$ACCESS_KEY" "$SECRET_KEY"
              fi

              echo "Granting permissions to ${access.key} for bucket ${access.bucket}"
              garage bucket allow ${access.bucket} \
                ${concatMapStrings (perm: "--${perm} ") access.permissions} \
                --key "$ACCESS_KEY"
            '') cfg.ensureAccess}
          '';

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = cfg.user;
            Group = cfg.group;
          };
        };
      };
    };

    services.nginx.virtualHosts = lib.mkIf cfg.exposeNginx {
      "s3.garage.${domain}" = {
        forceSSL = true;
        useACMEHost = domain;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString s3ApiPort}";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            proxy_buffering off;
            proxy_request_buffering off;

            client_max_body_size 5G;
            client_body_timeout 300s;
            proxy_connect_timeout 300s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
          '';
        };
      };

      "*.web.garage.${domain}" = {
        forceSSL = true;
        useACMEHost = domain;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString s3WebPort}";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
    };

    # RPC + admin ports are opened ONLY on the trusted interface, never on the
    # default zone. S3 API/web are never opened here — they reach the outside
    # solely through the nginx vhosts above.
    networking.firewall = mkIf (cfg.trustedInterface != null) {
      interfaces.${cfg.trustedInterface}.allowedTCPPorts = [
        rpcPort
        adminPort
      ];
    };
  };
}
