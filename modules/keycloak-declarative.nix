{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.modules.services.keycloak-declarative;

  # Build LoadCredential list for the configure service from all secret files
  configureCredentials =
    [ "admin-password:${cfg.initialAdminPasswordFile}" ]
    ++ concatLists (
      mapAttrsToList (
        realmName: realmConfig:
        (concatLists (
          mapAttrsToList (
            clientId: clientConfig:
            optional (clientConfig.secretFile != null) "client-${realmName}-${clientId}:${clientConfig.secretFile}"
          ) realmConfig.clients
        ))
        ++ (mapAttrsToList (
          username: userConfig: "user-${realmName}-${username}:${userConfig.passwordFile}"
        ) realmConfig.users)
      ) cfg.realms
    );
in
{
  options.modules.services.keycloak-declarative = {
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
      '';
      example = "0.0.0.0";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to open the Keycloak port in the firewall.
        In most deployments Keycloak sits behind a reverse proxy and
        should not be exposed directly.
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
          Required by the upstream NixOS keycloak module even when using Unix
          socket connections with peer authentication (the value is unused in
          that case but the file must exist).
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
                Passwords are re-applied on every run to enforce declared state.
              '';
            };

            groups = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    members = mkOption {
                      type = types.listOf types.str;
                      default = [ ];
                      description = ''
                        List of usernames that should belong to this group.
                        Users must be declared in the same realm's users attribute.
                      '';
                      example = [
                        "alice"
                        "bob"
                      ];
                    };
                  };
                }
              );
              default = { };
              description = ''
                Groups to create in this realm with their member assignments.
                Groups are created after users so that membership can be established.
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
        Each attempt waits for configurationRetryDelay seconds.
      '';
    };

    configurationRetryDelay = mkOption {
      type = types.int;
      default = 2;
      description = "Delay in seconds between configuration retry attempts.";
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
        authentication = mkIf (!cfg.database.useSocket) ''
          host    ${cfg.database.name} ${cfg.database.user} 127.0.0.1/32 scram-sha-256
        '';
      };

      # When using TCP, PostgreSQL needs the password set for scram-sha-256 auth.
      # ensureUsers creates the role without a password.
      systemd.services.keycloak-db-setup = mkIf (!cfg.database.useSocket) {
        description = "Set Keycloak PostgreSQL password for TCP authentication";
        after = [ "postgresql.service" "postgresql-setup.service" ];
        requires = [ "postgresql-setup.service" ];
        before = [ "keycloak.service" ];
        requiredBy = [ "keycloak.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
          LoadCredential = [ "db-password:${cfg.database.passwordFile}" ];
        };
        script = ''
          DB_PASS="$(cat "$CREDENTIALS_DIRECTORY/db-password")"
          echo "ALTER ROLE ${cfg.database.user} PASSWORD :'dbpass';" | \
            ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -v "dbpass=$DB_PASS"
        '';
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
          assertion = cfg.database.passwordFile != null;
          message = "Database password file is required for NixOS keycloak module compatibility";
        }
      ];

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

      # Using a separate service + EnvironmentFile because env vars exported
      # in preStart do not propagate to ExecStart (separate processes).
      systemd.services.keycloak-admin-env = {
        description = "Generate Keycloak admin environment file";
        after = [ "systemd-tmpfiles-setup.service" ];
        before = [ "keycloak.service" ];
        requiredBy = [ "keycloak.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [ "admin-password:${cfg.initialAdminPasswordFile}" ];
        };
        script = ''
          pw=$(cat "$CREDENTIALS_DIRECTORY/admin-password")
          printf 'KEYCLOAK_ADMIN_PASSWORD=%s\n' "$pw" > /run/keycloak/admin-env
          chmod 640 /run/keycloak/admin-env
          chown root:keycloak /run/keycloak/admin-env
        '';
      };

      systemd.services.keycloak = {
        after = [ "keycloak-admin-env.service" ];
        serviceConfig.EnvironmentFile = [ "/run/keycloak/admin-env" ];
        environment.KEYCLOAK_ADMIN = cfg.adminUser;
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/keycloak 0750 keycloak keycloak -"
        "d /run/keycloak 0750 keycloak keycloak -"
      ];

      users.users.keycloak = {
        isSystemUser = true;
        group = "keycloak";
        home = "/var/lib/keycloak";
      };

      users.groups.keycloak = { };

      systemd.services.keycloak-configure =
        let
          keycloakUrl = "http://localhost:${toString cfg.port}";

          configScript = pkgs.writeShellScript "keycloak-config" ''
            set -euo pipefail

            ADMIN_PASS=$(cat "$CREDENTIALS_DIRECTORY/admin-password")
            LAST_TOKEN_ERROR=""

            refresh_token() {
              local token_response new_token
              token_response=$(curl -s -X POST "${keycloakUrl}/realms/master/protocol/openid-connect/token" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -d "username=${cfg.adminUser}" \
                -d "password=$ADMIN_PASS" \
                -d "grant_type=password" \
                -d "client_id=admin-cli")

              new_token=$(echo "$token_response" | jq -r '.access_token // empty' 2>/dev/null)
              if [ -n "$new_token" ]; then
                TOKEN="$new_token"
                LAST_TOKEN_ERROR=""
                return 0
              fi
              LAST_TOKEN_ERROR=$(echo "$token_response" | jq -r '.error_description // .error // empty' 2>/dev/null)
              return 1
            }

            echo "Waiting for Keycloak admin API to be ready..."
            TOKEN=""
            for i in {1..${toString cfg.configurationAttempts}}; do
              if ! REALM_CHECK=$(curl -s -f ${keycloakUrl}/realms/master 2>/dev/null); then
                echo "Attempt $i/${toString cfg.configurationAttempts}: Keycloak not responding yet..."
                sleep ${toString cfg.configurationRetryDelay}
                continue
              fi

              if ! echo "$REALM_CHECK" | jq -e '.realm' > /dev/null 2>&1; then
                echo "Attempt $i/${toString cfg.configurationAttempts}: Keycloak responding but JSON invalid..."
                sleep ${toString cfg.configurationRetryDelay}
                continue
              fi

              if refresh_token; then
                echo "Successfully obtained admin token on attempt $i"
                break
              fi

              if [ -n "$LAST_TOKEN_ERROR" ]; then
                echo "Attempt $i/${toString cfg.configurationAttempts}: Token error: $LAST_TOKEN_ERROR"
              else
                echo "Attempt $i/${toString cfg.configurationAttempts}: Failed to get admin token, retrying..."
              fi

              sleep ${toString cfg.configurationRetryDelay}
            done

            if [ -z "$TOKEN" ]; then
              echo "ERROR: Failed to get admin token after ${toString cfg.configurationAttempts} attempts"
              exit 1
            fi

            ${concatStringsSep "\n" (
              mapAttrsToList (realmName: realmConfig: ''
                refresh_token || true
                echo "Configuring realm ${realmName}..."
                REALM_JSON=${escapeShellArg (builtins.toJSON {
                  realm = realmName;
                  displayName = realmConfig.displayName;
                  enabled = true;
                })}
                if ! curl -s -H "Authorization: Bearer $TOKEN" \
                    "${keycloakUrl}/admin/realms/${realmName}" | jq -e '.realm' > /dev/null 2>&1; then
                  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
                    "${keycloakUrl}/admin/realms" \
                    -H "Authorization: Bearer $TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "$REALM_JSON")
                  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                    echo "Created realm ${realmName}"
                  else
                    echo "ERROR: Failed to create realm ${realmName} (HTTP $HTTP_CODE)"
                    exit 1
                  fi
                else
                  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
                    "${keycloakUrl}/admin/realms/${realmName}" \
                    -H "Authorization: Bearer $TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "$REALM_JSON")
                  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                    echo "Updated realm ${realmName}"
                  else
                    echo "ERROR: Failed to update realm ${realmName} (HTTP $HTTP_CODE)"
                    exit 1
                  fi
                fi

                ${concatStringsSep "\n" (
                  mapAttrsToList (clientId: clientConfig: ''
                    refresh_token || true

                    ${optionalString (clientConfig.secretFile != null) ''
                      CLIENT_SECRET=$(cat "$CREDENTIALS_DIRECTORY/client-${realmName}-${clientId}")
                    ''}
                    ${optionalString (clientConfig.secretFile == null) ''
                      CLIENT_SECRET=$(openssl rand -base64 32)
                      echo "Generated client secret for ${clientId}: $CLIENT_SECRET"
                    ''}

                    EXISTING_CLIENT=$(curl -s -H "Authorization: Bearer $TOKEN" \
                        "${keycloakUrl}/admin/realms/${realmName}/clients" | \
                        jq --arg cid ${escapeShellArg clientId} '.[] | select(.clientId == $cid)')

                    CLIENT_JSON=${escapeShellArg (builtins.toJSON {
                      clientId = clientId;
                      enabled = true;
                      protocol = "openid-connect";
                      publicClient = false;
                      redirectUris = clientConfig.redirectUris;
                      standardFlowEnabled = true;
                      directAccessGrantsEnabled = true;
                      serviceAccountsEnabled = true;
                    })}
                    CLIENT_JSON=$(echo "$CLIENT_JSON" | jq --arg secret "$CLIENT_SECRET" '. + {secret: $secret}')

                    if [ -n "$EXISTING_CLIENT" ] && [ "$EXISTING_CLIENT" != "null" ]; then
                      CLIENT_UUID=$(echo "$EXISTING_CLIENT" | jq -r '.id')
                      echo "Updating client ${clientId} in realm ${realmName}..."
                      CLIENT_JSON=$(echo "$CLIENT_JSON" | jq --arg id "$CLIENT_UUID" '. + {id: $id}')
                      HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
                        "${keycloakUrl}/admin/realms/${realmName}/clients/$CLIENT_UUID" \
                        -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "$CLIENT_JSON")
                      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                        echo "Updated client ${clientId}"
                      else
                        echo "ERROR: Failed to update client ${clientId} (HTTP $HTTP_CODE)"
                        exit 1
                      fi
                    else
                      echo "Creating client ${clientId} in realm ${realmName}..."
                      HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
                        "${keycloakUrl}/admin/realms/${realmName}/clients" \
                        -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "$CLIENT_JSON")
                      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                        echo "Created client ${clientId}"
                      else
                        echo "ERROR: Failed to create client ${clientId} (HTTP $HTTP_CODE)"
                        exit 1
                      fi
                    fi
                  '') realmConfig.clients
                )}

                ${concatStringsSep "\n" (
                  mapAttrsToList (username: userConfig: ''
                    refresh_token || true
                    USER_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/user-${realmName}-${username}")

                    EXISTING_USER=$(curl -s -H "Authorization: Bearer $TOKEN" \
                        "${keycloakUrl}/admin/realms/${realmName}/users?username=${username}&exact=true" | \
                        jq --arg u ${escapeShellArg username} '.[] | select(.username == $u)')

                    USER_JSON=${escapeShellArg (builtins.toJSON {
                      username = username;
                      email = userConfig.email;
                      firstName = userConfig.firstName;
                      lastName = userConfig.lastName;
                      enabled = true;
                      emailVerified = true;
                    })}

                    if [ -n "$EXISTING_USER" ] && [ "$EXISTING_USER" != "null" ]; then
                      USER_ID=$(echo "$EXISTING_USER" | jq -r '.id')
                      echo "Updating user ${username} in realm ${realmName}..."
                      HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
                        "${keycloakUrl}/admin/realms/${realmName}/users/$USER_ID" \
                        -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "$USER_JSON")
                      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                        echo "Updated user ${username}"
                      else
                        echo "ERROR: Failed to update user ${username} (HTTP $HTTP_CODE)"
                        exit 1
                      fi
                    else
                      echo "Creating user ${username} in realm ${realmName}..."
                      USER_CREATE_RESPONSE=$(curl -s -i -X POST "${keycloakUrl}/admin/realms/${realmName}/users" \
                        -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "$USER_JSON")
                      USER_ID=$(echo "$USER_CREATE_RESPONSE" | grep -i '^location:' | grep -o '[^/]*$' | tr -d '\r\n') || true
                      if [ -z "$USER_ID" ]; then
                        echo "ERROR: Failed to get user ID for ${username} after creation"
                        exit 1
                      fi
                      echo "Created user ${username}"
                    fi

                    # Passwords are always re-applied to enforce declared state
                    PASSWORD_JSON=$(jq -n --arg pw "$USER_PASSWORD" '{type:"password",value:$pw,temporary:false}')
                    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
                      "${keycloakUrl}/admin/realms/${realmName}/users/$USER_ID/reset-password" \
                      -H "Authorization: Bearer $TOKEN" \
                      -H "Content-Type: application/json" \
                      -d "$PASSWORD_JSON")
                    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                      echo "Password set for ${username}"
                    else
                      echo "ERROR: Failed to set password for ${username} (HTTP $HTTP_CODE)"
                      exit 1
                    fi
                  '') realmConfig.users
                )}

                ${concatStringsSep "\n" (
                  mapAttrsToList (groupName: groupConfig: ''
                    refresh_token || true

                    GROUP_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
                        "${keycloakUrl}/admin/realms/${realmName}/groups?search=${groupName}&exact=true" | \
                        jq -r --arg g ${escapeShellArg groupName} '.[] | select(.name == $g) | .id // empty')

                    if [ -z "$GROUP_ID" ]; then
                      echo "Creating group ${groupName} in realm ${realmName}..."
                      HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
                        "${keycloakUrl}/admin/realms/${realmName}/groups" \
                        -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/json" \
                        -d ${escapeShellArg (builtins.toJSON { name = groupName; })})
                      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                        echo "Created group ${groupName}"
                      else
                        echo "ERROR: Failed to create group ${groupName} (HTTP $HTTP_CODE)"
                        exit 1
                      fi
                      GROUP_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
                          "${keycloakUrl}/admin/realms/${realmName}/groups?search=${groupName}&exact=true" | \
                          jq -r --arg g ${escapeShellArg groupName} '.[] | select(.name == $g) | .id')
                    else
                      echo "Group ${groupName} already exists in realm ${realmName}"
                    fi

                    ${concatStringsSep "\n" (
                      map (member: ''
                        MEMBER_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
                            "${keycloakUrl}/admin/realms/${realmName}/users?username=${member}&exact=true" | \
                            jq -r --arg u ${escapeShellArg member} '.[] | select(.username == $u) | .id // empty')
                        if [ -n "$MEMBER_ID" ]; then
                          HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
                            "${keycloakUrl}/admin/realms/${realmName}/users/$MEMBER_ID/groups/$GROUP_ID" \
                            -H "Authorization: Bearer $TOKEN")
                          if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
                            echo "Added ${member} to group ${groupName}"
                          else
                            echo "ERROR: Failed to add ${member} to group ${groupName} (HTTP $HTTP_CODE)"
                            exit 1
                          fi
                        else
                          echo "Warning: User ${member} not found, cannot add to group ${groupName}"
                        fi
                      '') groupConfig.members
                    )}
                  '') realmConfig.groups
                )}
              '') cfg.realms
            )}

            echo "Keycloak configuration completed"
          '';
        in
        {
          description = "Configure Keycloak realms, clients, users, and groups";
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
            LoadCredential = configureCredentials;
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
