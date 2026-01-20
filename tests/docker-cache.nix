{
  pkgs,
  lib,
  ...
}:
# Simplified docker-cache test that verifies configuration without running Docker
pkgs.testers.nixosTest {
  name = "docker-cache";

  nodes = {
    # Docker cache proxy server - test configuration only
    cache =
      { config, pkgs, ... }:
      {
        imports = [ ../modules/docker-cache.nix ];

        # Enable docker but don't start containers in test
        virtualisation.docker.enable = true;

        modules.services.docker-cache = {
          enable = true;
          domain = "docker-cache.test";
          acmeHost = "test";
          enableSSL = false;
          cacheDir = "/var/cache/docker-registry-proxy";
          maxSize = "10g";
        };

        # Disable the actual docker container for faster testing
        systemd.services."docker-docker-registry-proxy".wantedBy = lib.mkForce [ ];
      };

    # Client using the cache
    client =
      { config, pkgs, ... }:
      {
        imports = [ ../behaviors/use-docker-cache.nix ];

        virtualisation.docker.enable = true;

        behaviors.docker-cache = {
          enable = true;
          cacheUrl = "http://docker-cache.test";
        };
      };
  };

  testScript = ''
    def test_configuration():
        """Test configuration is valid"""
        # Verify cache directories are created
        cache.succeed("test -d /var/cache/docker-registry-proxy")
        cache.succeed("test -d /var/cache/docker-registry-proxy/cache")
        cache.succeed("test -d /var/cache/docker-registry-proxy/ca")

    def test_nginx_config():
        """Test nginx is configured and running"""
        cache.wait_for_unit("nginx.service")
        cache.wait_for_open_port(80)
        # Verify nginx service is active
        cache.succeed("systemctl is-active nginx.service")

    def test_client_configuration():
        """Test client Docker configuration"""
        client.wait_for_unit("docker.service")
        # Verify docker daemon config file exists and contains proxy settings
        config = client.succeed("cat /etc/docker/daemon.json")
        assert "registry-mirrors" in config or "proxies" in config, "Docker proxy config missing"

    # Start all nodes
    start_all()

    # Run tests
    with subtest("Testing configuration"):
        test_configuration()

    with subtest("Testing nginx config"):
        test_nginx_config()

    with subtest("Testing client configuration"):
        test_client_configuration()

    print("All Docker cache tests passed!")
  '';
}
