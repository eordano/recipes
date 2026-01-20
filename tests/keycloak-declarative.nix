{ pkgs, ... }:

pkgs.testers.runNixOSTest {
  name = "keycloak-declarative";
  meta = with pkgs.lib.maintainers; {
    maintainers = [ ];
  };

  nodes = {
    server =
      { config, pkgs, ... }:
      {
        imports = [
          ../modules/keycloak-declarative.nix
        ];

        system.stateVersion = "24.11";

        # Pin PostgreSQL version
        services.postgresql.package = pkgs.postgresql_17;

        # Create test password files
        systemd.tmpfiles.rules = [
          "f /tmp/keycloak-admin-password 0644 root root - admin123"
          "f /tmp/test-user-password 0644 root root - testpass123"
          "f /tmp/gitea-client-secret 0644 root root - gitea-secret-123"
          "f /tmp/keycloak-db-password 0644 root root - dbpass123"
        ];

        modules.services.keycloak-declarative = {
          enable = true;
          hostname = "localhost";
          port = 8080;
          bindAddress = "0.0.0.0";
          openFirewall = true;

          database = {
            createLocally = true;
            useSocket = false;
            host = "127.0.0.1";
            passwordFile = "/tmp/keycloak-db-password";
          };

          initialAdminPasswordFile = "/tmp/keycloak-admin-password";

          realms = {
            master = {
              displayName = "Master Realm";
              clients = {
                gitea = {
                  redirectUris = [
                    "http://localhost:3000/user/oauth2/decent.foundation"
                    "http://localhost:3000/*"
                  ];
                  secretFile = "/tmp/gitea-client-secret";
                };
              };
              users = {
                testuser = {
                  email = "test@example.com";
                  firstName = "Test";
                  lastName = "User";
                  passwordFile = "/tmp/test-user-password";
                };
              };
              groups = {
                developers = {
                  members = [ "testuser" ];
                };
              };
            };
          };
        };

        # Disable SSL for JDBC in test VM (no SSL certs configured)
        services.keycloak.database.useSSL = false;
      };
  };

  testScript = ''
    import json

    server.start()
    server.wait_for_unit("multi-user.target")

    # Wait for PostgreSQL
    server.wait_for_unit("postgresql.service")
    server.wait_for_open_port(5432)

    # Wait for Keycloak service
    server.wait_for_unit("keycloak.service")
    server.wait_for_open_port(8080)

    # Wait for Keycloak to respond
    print("Waiting for Keycloak to be ready...")
    server.wait_until_succeeds("curl -f http://localhost:8080/realms/master", timeout=120)

    # Wait for configuration service
    print("Waiting for Keycloak configuration...")
    try:
        server.wait_for_unit("keycloak-configure.service", timeout=120)
    except Exception as e:
        print("keycloak-configure.service failed, showing logs:")
        server.succeed("journalctl -u keycloak-configure.service --no-pager || true")
        raise e

    # Test admin login and token retrieval
    print("Testing admin authentication...")
    result = server.succeed("""
      curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=admin" \
        -d "password=admin123" \
        -d "grant_type=password" \
        -d "client_id=admin-cli"
    """)

    token_response = json.loads(result)
    assert "access_token" in token_response, f"No access token in response: {result}"
    token = token_response["access_token"]
    print("Admin authentication successful")

    # Test realm display name was updated by the module
    print("Testing realm configuration...")
    result = server.succeed(f"""
      curl -s -H "Authorization: Bearer {token}" \
        "http://localhost:8080/admin/realms/master"
    """)
    realm_info = json.loads(result)
    assert realm_info["displayName"] == "Master Realm", f"Wrong display name: {realm_info}"
    print("Realm configuration correct")

    # Test client exists with correct settings
    print("Testing client configuration...")
    result = server.succeed(f"""
      curl -s -H "Authorization: Bearer {token}" \
        "http://localhost:8080/admin/realms/master/clients"
    """)
    clients = json.loads(result)
    gitea_clients = [c for c in clients if c.get("clientId") == "gitea"]
    assert len(gitea_clients) == 1, f"Gitea client not found or duplicated: {len(gitea_clients)}"

    gitea_client = gitea_clients[0]
    expected_redirects = [
      "http://localhost:3000/user/oauth2/decent.foundation",
      "http://localhost:3000/*"
    ]
    assert gitea_client["redirectUris"] == expected_redirects, f"Wrong redirect URIs: {gitea_client['redirectUris']}"
    print("Client configuration correct")

    # Test client secret
    print("Testing client secret...")
    result = server.succeed(f"""
      curl -s -H "Authorization: Bearer {token}" \
        "http://localhost:8080/admin/realms/master/clients/{gitea_client['id']}/client-secret"
    """)
    secret_info = json.loads(result)
    assert "value" in secret_info, f"No client secret found: {secret_info}"
    assert secret_info["value"] == "gitea-secret-123", f"Wrong client secret: {secret_info['value']}"
    print("Client secret configured correctly")

    # Test user exists with correct attributes
    print("Testing user configuration...")
    result = server.succeed(f"""
      curl -s -H "Authorization: Bearer {token}" \
        "http://localhost:8080/admin/realms/master/users?username=testuser"
    """)
    users = json.loads(result)
    assert len(users) == 1, f"Test user not found: {len(users)}"

    user = users[0]
    assert user["username"] == "testuser", f"Wrong username: {user['username']}"
    assert user["email"] == "test@example.com", f"Wrong email: {user['email']}"
    assert user["firstName"] == "Test", f"Wrong first name: {user['firstName']}"
    assert user["lastName"] == "User", f"Wrong last name: {user['lastName']}"
    assert user["enabled"] == True, f"User not enabled: {user['enabled']}"
    assert user["emailVerified"] == True, f"Email not verified: {user['emailVerified']}"
    print("User configuration correct")

    # Test group exists and has correct membership
    print("Testing group configuration...")
    result = server.succeed(f"""
      curl -s -H "Authorization: Bearer {token}" \
        "http://localhost:8080/admin/realms/master/groups"
    """)
    groups = json.loads(result)
    dev_groups = [g for g in groups if g.get("name") == "developers"]
    assert len(dev_groups) == 1, f"developers group not found: {[g.get('name') for g in groups]}"

    group_id = dev_groups[0]["id"]
    result = server.succeed(f"""
      curl -s -H "Authorization: Bearer {token}" \
        "http://localhost:8080/admin/realms/master/groups/{group_id}/members"
    """)
    members = json.loads(result)
    member_names = [m["username"] for m in members]
    assert "testuser" in member_names, f"testuser not in developers group: {member_names}"
    print("Group configuration correct")

    # Test user authentication via OIDC password grant
    print("Testing user authentication...")
    result = server.succeed("""
      curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=testuser" \
        -d "password=testpass123" \
        -d "grant_type=password" \
        -d "client_id=gitea" \
        -d "client_secret=gitea-secret-123"
    """)
    user_token_response = json.loads(result)
    assert "access_token" in user_token_response, f"User authentication failed: {result}"
    print("User authentication successful")

    # Test OIDC discovery endpoint - verifies the full OIDC stack is functional
    print("Testing OIDC discovery...")
    result = server.succeed("""
      curl -s "http://localhost:8080/realms/master/.well-known/openid-configuration"
    """)
    discovery = json.loads(result)
    for endpoint in ["authorization_endpoint", "token_endpoint", "userinfo_endpoint", "jwks_uri"]:
      assert endpoint in discovery, f"Missing OIDC endpoint: {endpoint}"
    print("OIDC discovery configuration correct")

    print("All tests passed!")
  '';
}
