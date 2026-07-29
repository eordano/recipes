{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.keycloak-declarative;
in
{
  options.services.keycloak-declarative = {
    enable = mkEnableOption "declarative Keycloak configuration with automated realm and client setup";

    hostname = mkOption {
      type = types.str;
      default = "localhost";
      description = ''
        Hostname where Keycloak will be accessible.
        This is used for both binding and as the canonical URL for the service.
      '';
      example = "auth.example.com";
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = ''
        Port number where Keycloak will listen for HTTP connections.
        Note: This module currently only supports HTTP mode.
      '';
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        IP address that Keycloak should bind to.
        Use "0.0.0.0" to listen on all interfaces.

        WARNING: this module serves Keycloak over plain HTTP (including the
        admin console and the admin-cli password-grant token endpoint). Binding
        to a non-loopback address exposes those credentials in cleartext. Only
        bind beyond 127.0.0.1 behind a TLS-terminating reverse proxy — never
        reach the port directly from another host.
      '';
      example = "0.0.0.0";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to open `port` in the firewall.
        Left closed by default: with the safe `bindAddress = "127.0.0.1"` only a
        local reverse proxy needs the port, so no hole is required. Enable this
        only when you deliberately bind to a non-loopback address AND front the
        service with TLS — the listener is plain HTTP.
      '';
    };

    database = {
      type = mkOption {
        type = types.enum [ "postgresql" ];
        default = "postgresql";
        description = "Database type to use";
      };

      host = mkOption {
        type = types.str;
        default = "/run/postgresql";
        description = ''
          Database host address.
          - Use "/run/postgresql" for Unix socket connections (recommended for local databases)
          - Use hostname or IP address for TCP connections to remote databases
        '';
        example = "localhost";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = ''
          Database port number.
          This is ignored when using Unix socket connections.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "keycloak";
        description = "Database name";
      };

      user = mkOption {
        type = types.str;
        default = "keycloak";
        description = "Database user";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing the database password.
          Not required when using Unix socket connections with peer authentication.
          The file should contain only the password with no trailing newline.
        '';
        example = "/run/secrets/keycloak-db-password";
      };

      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to automatically create and manage a local PostgreSQL database.
          When enabled, this will configure PostgreSQL with the necessary database and user.
        '';
      };

      useSocket = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to use Unix socket connections instead of TCP.
          This is more secure and efficient for local database connections.
        '';
      };
    };

    adminUser = mkOption {
      type = types.str;
      default = "admin";
      description = ''
        Username for the Keycloak administrative user.
        This user will have full access to all realms and configuration.
      '';
    };

    initialAdminPasswordFile = mkOption {
      type = types.str;
      description = ''
        Path to a file containing the initial admin password.
        This password will be used for the first login and should be changed afterwards.
        The file should contain only the password with no trailing newline.
      '';
      example = "/run/secrets/keycloak-admin-password";
    };

    realms = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            displayName = mkOption {
              type = types.str;
              description = ''
                Human-readable display name for the realm.
                This is shown in the Keycloak UI and login pages.
              '';
              example = "My Organization";
            };

            clients = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    redirectUris = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = ''
                        List of valid redirect URIs for OAuth/OIDC flows.
                        These are the URLs where Keycloak can redirect after authentication.
                        Use "*" for development only - always specify exact URIs in production.
                      '';
                      example = [
                        "https://app.example.com/oauth/callback"
                        "https://app.example.com/logout"
                      ];
                    };

                    secretFile = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = ''
                        Path to a file containing the client secret.
                        If not provided, a random secret will be generated and printed to the journal.
                        The file should contain only the secret with no trailing newline.
                      '';
                      example = "/run/secrets/oauth-client-secret";
                    };
                  };
                }
              );
              default = { };
              description = ''
                OpenID Connect (OIDC) clients configuration for this realm.
                Each client represents an application that can authenticate users.
              '';
            };

            users = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    email = mkOption {
                      type = types.str;
                      description = ''
                        Email address for the user.
                        This will be marked as verified by default.
                      '';
                      example = "user@example.com";
                    };

                    firstName = mkOption {
                      type = types.str;
                      default = "";
                      description = "User first name";
                    };

                    lastName = mkOption {
                      type = types.str;
                      default = "";
                      description = "User last name";
                    };

                    passwordFile = mkOption {
                      type = types.str;
                      description = ''
                        Path to a file containing the user's password.
                        The password will be set as permanent (not temporary).
                        The file should contain only the password with no trailing newline.
                      '';
                      example = "/run/secrets/user-password";
                    };
                  };
                }
              );
              default = { };
              description = ''
                User accounts to create in this realm.
                Users will be created with verified emails and permanent passwords.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Keycloak realms to create and configure.
        Each realm is an isolated namespace for users, clients, and settings.
      '';
    };

    configurationAttempts = mkOption {
      type = types.int;
      default = 60;
      description = ''
        Number of attempts to wait for Keycloak to be ready before configuration.
        Each attempt waits `configurationRetryDelay` seconds.
      '';
    };

    configurationRetryDelay = mkOption {
      type = types.int;
      default = 2;
      description = ''
        Delay in seconds between configuration retry attempts.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (cfg.database.type == "postgresql" && cfg.database.createLocally) {
      services.postgresql = {
        enable = true;
        ensureDatabases = [ cfg.database.name ];
        ensureUsers = [
          {
            name = cfg.database.user;
            ensureDBOwnership = true;
          }
        ];
      };
    })

    {
      assertions = [
        {
          assertion = cfg.database.type == "postgresql" || !cfg.database.createLocally;
          message = "Only PostgreSQL is supported for local database creation";
        }
        {
          assertion = cfg.database.useSocket -> cfg.database.host == "/run/postgresql";
          message = "When using socket connections, database.host must be /run/postgresql";
        }
        {
          assertion = !cfg.database.useSocket -> cfg.database.passwordFile != null;
          message = "Database password file is required when not using socket connections";
        }
        {
          assertion = cfg.database.passwordFile != null;
          message = "Database password file is required for NixOS keycloak module compatibility";
        }
        {
          assertion = cfg.port >= 1024 || cfg.bindAddress == "127.0.0.1";
          message = "Ports below 1024 require root privileges. Use a higher port or bind to localhost only";
        }
      ];

      services.postgresql = mkIf (cfg.database.createLocally && cfg.database.type == "postgresql") {
        authentication = mkIf (!cfg.database.useSocket) ''
          host    ${cfg.database.name} ${cfg.database.user} 127.0.0.1/32 scram-sha-256
        '';
      };

      services.keycloak = {
        enable = true;
        settings = {
          hostname = cfg.hostname;
          http-host = cfg.bindAddress;
          http-port = cfg.port;
          http-enabled = true;
          hostname-strict = false;
          hostname-strict-https = false;
        };
        database = {
          type = "postgresql";
          host = cfg.database.host;
          port = cfg.database.port;
          name = cfg.database.name;
          username = cfg.database.user;
          passwordFile = cfg.database.passwordFile;
        };
      };

      # The admin password must exist in an EnvironmentFile before keycloak.service
      # starts. systemd resolves EnvironmentFile *before* running ExecStartPre, so a
      # preStart hook is too late — a separate `before=` oneshot is required.
      systemd.services.keycloak = {
        requires = [ "keycloak-admin-setup.service" ];
        after = [ "keycloak-admin-setup.service" ];
        serviceConfig = {
          EnvironmentFile = "/run/keycloak/admin-env";
        };
        environment = {
          KEYCLOAK_ADMIN = cfg.adminUser;
        };
      };

      # Runs as the keycloak user, not root: RuntimeDirectory already creates
      # /run/keycloak owned by it, and LoadCredential lets PID1 (still root)
      # read initialAdminPasswordFile on the unit's behalf and hand it over
      # through $CREDENTIALS_DIRECTORY regardless of that file's own
      # permissions -- so nothing here needs a privileged chown/cat.
      systemd.services.keycloak-admin-setup = {
        description = "Prepare Keycloak admin credentials";
        before = [ "keycloak.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "keycloak";
          Group = "keycloak";
          RuntimeDirectory = "keycloak";
          RuntimeDirectoryMode = "0750";
          LoadCredential = "admin-password:${cfg.initialAdminPasswordFile}";
        };
        script = ''
          ADMIN_PW=$(cat "$CREDENTIALS_DIRECTORY/admin-password")
          printf 'KEYCLOAK_ADMIN_PASSWORD=%s\n' "$ADMIN_PW" > /run/keycloak/admin-env
          chmod 600 /run/keycloak/admin-env
        '';
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/keycloak 0750 keycloak keycloak -"
      ];

      users.users.keycloak = {
        isSystemUser = true;
        group = "keycloak";
        home = "/var/lib/keycloak";
      };

      users.groups.keycloak = { };

      systemd.services.keycloak-configure =
        let
          # Must talk to localhost: the `master` realm defaults to
          # sslRequired=external, which rejects plain-HTTP requests from any
          # non-local address. A loopback URL is exempt.
          keycloakUrl = "http://localhost:${toString cfg.port}";

          configScript = pkgs.writeShellScript "keycloak-config" ''
            set -euo pipefail

            ADMIN_PASS=$(cat ${cfg.initialAdminPasswordFile})

            refresh_token() {
              local token_response
              token_response=$(curl -s -X POST "${keycloakUrl}/realms/master/protocol/openid-connect/token" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -d "username=${cfg.adminUser}" \
                -d "password=$ADMIN_PASS" \
                -d "grant_type=password" \
                -d "client_id=admin-cli" 2>&1)

              TOKEN=$(echo "$token_response" | ${pkgs.jq}/bin/jq -r '.access_token // empty' 2>/dev/null)
              if [ -n "$TOKEN" ]; then
                return 0
              fi
              return 1
            }

            echo "Waiting for Keycloak admin API to be ready..."
            TOKEN=""
            for i in {1..${toString cfg.configurationAttempts}}; do
              if ! REALM_CHECK=$(curl -s -f ${keycloakUrl}/realms/master 2>&1); then
                echo "Attempt $i/${toString cfg.configurationAttempts}: Keycloak not responding yet..."
                sleep ${toString cfg.configurationRetryDelay}
                continue
              fi

              if ! echo "$REALM_CHECK" | ${pkgs.jq}/bin/jq -e '.realm' > /dev/null 2>&1; then
                echo "Attempt $i/${toString cfg.configurationAttempts}: Keycloak responding but JSON invalid..."
                sleep ${toString cfg.configurationRetryDelay}
                continue
              fi

              if refresh_token; then
                echo "Successfully obtained admin token on attempt $i"
                break
              fi

              TOKEN_RESPONSE=$(curl -s -X POST "${keycloakUrl}/realms/master/protocol/openid-connect/token" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -d "username=${cfg.adminUser}" \
                -d "password=$ADMIN_PASS" \
                -d "grant_type=password" \
                -d "client_id=admin-cli" 2>&1)
              TOKEN_ERROR=$(echo "$TOKEN_RESPONSE" | ${pkgs.jq}/bin/jq -r '.error_description // .error // empty' 2>/dev/null)
              if [ -n "$TOKEN_ERROR" ]; then
                echo "Attempt $i/${toString cfg.configurationAttempts}: Token error: $TOKEN_ERROR"
              else
                echo "Attempt $i/${toString cfg.configurationAttempts}: Failed to get admin token, retrying..."
              fi

              sleep ${toString cfg.configurationRetryDelay}
            done

            if [ -z "$TOKEN" ]; then
              echo "ERROR: Failed to get admin token after ${toString cfg.configurationAttempts} attempts"
              echo "Server not available. Configure failed."
              exit 1
            fi

            ${concatStringsSep "\n" (
              mapAttrsToList (realmName: realmConfig: ''
                echo "Checking realm ${realmName}..."
                if ! curl -s -H "Authorization: Bearer $TOKEN" \
                    "${keycloakUrl}/admin/realms/${realmName}" | jq -e '.realm' > /dev/null 2>&1; then
                  echo "Creating realm ${realmName}..."
                  curl -s -X POST "${keycloakUrl}/admin/realms" \
                    -H "Authorization: Bearer $TOKEN" \
                    -H "Content-Type: application/json" \
                    -d '${
                      builtins.toJSON {
                        realm = realmName;
                        displayName = realmConfig.displayName;
                        enabled = true;
                      }
                    }'
                  echo "Successfully created realm ${realmName}"
                else
                  echo "Realm ${realmName} already exists, updating displayName..."
                  CURRENT_REALM=$(curl -s -H "Authorization: Bearer $TOKEN" "${keycloakUrl}/admin/realms/${realmName}")
                  UPDATED_REALM=$(echo "$CURRENT_REALM" | ${pkgs.jq}/bin/jq --arg dn '${realmConfig.displayName}' '.displayName = $dn')
                  curl -s -X PUT "${keycloakUrl}/admin/realms/${realmName}" \
                    -H "Authorization: Bearer $TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "$UPDATED_REALM"
                  echo "Successfully updated realm ${realmName}"
                fi

                ${concatStringsSep "\n" (
                  mapAttrsToList (clientId: clientConfig: ''
                    refresh_token || true
                    if ! curl -s -H "Authorization: Bearer $TOKEN" \
                        "${keycloakUrl}/admin/realms/${realmName}/clients" | \
                        jq -e ".[] | select(.clientId == \"${clientId}\")" > /dev/null; then
                      echo "Creating client ${clientId} in realm ${realmName}..."
                      ${lib.optionalString (clientConfig.secretFile != null) ''
                        CLIENT_SECRET=$(cat ${clientConfig.secretFile})
                      ''}
                      ${lib.optionalString (clientConfig.secretFile == null) ''
                        CLIENT_SECRET=$(openssl rand -base64 32)
                        echo "Generated client secret for ${clientId}: $CLIENT_SECRET"
                      ''}
                      CLIENT_JSON=${
                        lib.escapeShellArg (
                          builtins.toJSON {
                            clientId = clientId;
                            enabled = true;
                            protocol = "openid-connect";
                            publicClient = false;
                            redirectUris = clientConfig.redirectUris;
                            standardFlowEnabled = true;
                            directAccessGrantsEnabled = true;
                            serviceAccountsEnabled = true;
                          }
                        )
                      }
                      CLIENT_JSON=$(echo "$CLIENT_JSON" | ${pkgs.jq}/bin/jq --arg secret "$CLIENT_SECRET" '. + {secret: $secret}')
                      curl -s -X POST "${keycloakUrl}/admin/realms/${realmName}/clients" \
                        -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "$CLIENT_JSON"
                      echo "Successfully created client ${clientId}"
                    else
                      echo "Client ${clientId} already exists in realm ${realmName}, skipping..."
                    fi
                  '') realmConfig.clients
                )}

                ${concatStringsSep "\n" (
                  mapAttrsToList (username: userConfig: ''
                    refresh_token || true
                    if ! curl -s -H "Authorization: Bearer $TOKEN" \
                        "${keycloakUrl}/admin/realms/${realmName}/users?username=${username}" | \
                        jq -e ".[] | select(.username == \"${username}\")" > /dev/null; then
                      echo "Creating user ${username} in realm ${realmName}..."
                      USER_PASSWORD=$(cat ${userConfig.passwordFile})

                      USER_CREATE_RESPONSE=$(curl -s -i -X POST "${keycloakUrl}/admin/realms/${realmName}/users" \
                        -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/json" \
                        -d '${
                          builtins.toJSON {
                            username = username;
                            email = userConfig.email;
                            firstName = userConfig.firstName;
                            lastName = userConfig.lastName;
                            enabled = true;
                            emailVerified = true;
                          }
                        }')
                      USER_ID=$(echo "$USER_CREATE_RESPONSE" | grep -i '^location:' | grep -o '[^/]*$' | tr -d '\r\n') || true

                      if [ -n "$USER_ID" ]; then
                        PASSWORD_JSON=$(${pkgs.jq}/bin/jq -n --arg pw "$USER_PASSWORD" '{type:"password",value:$pw,temporary:false}')
                        curl -s -X PUT "${keycloakUrl}/admin/realms/${realmName}/users/$USER_ID/reset-password" \
                          -H "Authorization: Bearer $TOKEN" \
                          -H "Content-Type: application/json" \
                          -d "$PASSWORD_JSON"
                        echo "Successfully created user ${username}"
                      else
                        echo "Warning: Failed to get user ID for ${username}"
                      fi
                    else
                      echo "User ${username} already exists in realm ${realmName}, skipping..."
                    fi
                  '') realmConfig.users
                )}
              '') cfg.realms
            )}

            echo "Keycloak configuration completed"
          '';
        in
        {
          description = "Configure Keycloak realms and clients";
          after = [
            "keycloak.service"
            "postgresql.service"
          ];
          wants = [ "keycloak.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "nobody";
            Group = "nogroup";
            TimeoutStartSec = "5m";
          };

          path = [
            pkgs.curl
            pkgs.jq
            pkgs.openssl
          ];
          script = "${configScript}";
        };

      networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
    }
  ]);
}
