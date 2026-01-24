{
  pkgs,
  lib,
  ...
}:
let
  # Minimal test image streamer (produces proper OCI layer media types)
  testImage = pkgs.dockerTools.streamLayeredImage {
    name = "test-image";
    tag = "latest";
    contents = [ pkgs.coreutils ];
    config.Cmd = [ "${pkgs.coreutils}/bin/true" ];
  };
in
pkgs.testers.nixosTest {
  name = "docker-cache";

  nodes = {
    # Upstream Docker registry
    registry =
      { config, pkgs, ... }:
      {
        services.dockerRegistry = {
          enable = true;
          listenAddress = "0.0.0.0";
          port = 5000;
        };

        virtualisation.docker.enable = true;
        virtualisation.docker.daemon.settings = {
          "insecure-registries" = [ "localhost:5000" ];
        };

        networking.firewall.allowedTCPPorts = [ 5000 ];
      };

    # Docker cache proxy server running rpardini/docker-registry-proxy
    cache =
      { config, pkgs, ... }:
      {
        imports = [ ../modules/docker-cache.nix ];

        virtualisation.memorySize = 2048;
        virtualisation.diskSize = 4096;
        virtualisation.docker.enable = true;

        modules.services.docker-cache = {
          enable = true;
          domain = "cache";
          acmeHost = "test";
          enableSSL = false;
          cacheDir = "/var/cache/docker-registry-proxy";
          maxSize = "5g";
          registries = [ "registry:5000" ];
        };

        # Run dnsmasq on the host so the container can resolve "registry"
        # via the Docker bridge gateway. dnsmasq reads /etc/hosts which
        # has entries for all test VMs.
        services.dnsmasq = {
          enable = true;
          settings = {
            no-resolv = true;
            no-poll = true;
            listen-address = "0.0.0.0";
          };
        };

        # Point the container's DNS to the Docker bridge gateway (host).
        # The host's dnsmasq resolves "registry" from /etc/hosts.
        virtualisation.oci-containers.containers.docker-registry-proxy.extraOptions = lib.mkForce [
          "--add-host=docker-registry-proxy:127.0.0.1"
          "--dns=172.17.0.1"
        ];

        # Disable firewall to allow Docker NAT forwarding and direct port access
        networking.firewall.enable = false;
      };

    # Client that pulls images through the cache proxy
    client =
      { config, pkgs, ... }:
      {
        imports = [ ../behaviors/use-docker-cache.nix ];

        virtualisation.memorySize = 2048;
        virtualisation.diskSize = 4096;
        virtualisation.docker.enable = true;

        # Disable IPv6 so Docker connects to the cache proxy via IPv4
        # (rpardini only listens on 0.0.0.0, not [::])
        networking.enableIPv6 = false;

        behaviors.docker-cache = {
          enable = true;
          cacheUrl = "http://cache";
        };

        # Allow pulling from the insecure (HTTP) test registry
        virtualisation.docker.daemon.settings = {
          "insecure-registries" = [ "registry:5000" ];
        };
      };
  };

  testScript = ''
    def test_registry_service():
        """Test the Docker registry is running and healthy"""
        registry.wait_for_unit("docker-registry.service")
        registry.wait_for_open_port(5000)
        registry.succeed("curl -f http://localhost:5000/v2/")

    def test_push_image():
        """Push the test image to the registry using Docker"""
        registry.wait_for_unit("docker.service")
        registry.succeed("${testImage} | docker load")
        registry.succeed("docker tag test-image:latest localhost:5000/test-image:latest")
        registry.succeed("docker push localhost:5000/test-image:latest")
        result = registry.succeed("curl -f http://localhost:5000/v2/_catalog")
        assert "test-image" in result, f"test-image not in catalog: {result}"

    def test_cache_services():
        """Test the cache proxy stack starts correctly"""
        cache.wait_for_unit("docker.service")
        cache.wait_until_succeeds(
            "docker ps --format '{{.Names}}' | grep -q docker-registry-proxy",
            timeout=120
        )
        cache.wait_for_open_port(3128)
        cache.wait_for_unit("nginx.service")
        cache.wait_for_open_port(80)

    def test_cache_ca_cert():
        """Test the CA certificate is generated and served"""
        cache.wait_for_unit("docker-registry-proxy-ca-export.service", timeout=180)
        cache.succeed("test -f /var/lib/nginx/docker-registry-proxy/ca.crt")
        result = cache.succeed("curl -f http://localhost/ca.crt")
        assert "BEGIN CERTIFICATE" in result, "CA cert not served correctly"

    def test_cache_reaches_registry():
        """Test the cache node can reach the registry"""
        cache.succeed("curl -f http://registry:5000/v2/")

    def test_client_docker_config():
        """Test client Docker has proxy settings"""
        client.wait_for_unit("docker.service")
        info = client.succeed("docker info")
        assert "cache" in info or "3128" in info, \
            f"Proxy config not in docker info: {info}"

    def test_client_pull():
        """Pull the test image from registry through the cache proxy"""
        client.succeed("docker pull registry:5000/test-image:latest")

    def test_image_works():
        """Verify the pulled image exists and runs"""
        result = client.succeed("docker images --format '{{.Repository}}:{{.Tag}}'")
        assert "registry:5000/test-image:latest" in result, \
            f"Image not found: {result}"
        client.succeed("docker run --rm registry:5000/test-image:latest /bin/true")

    # === Execute tests ===
    start_all()

    with subtest("Registry is accessible"):
        test_registry_service()

    with subtest("Push test image to registry"):
        test_push_image()

    with subtest("Cache services start"):
        test_cache_services()

    with subtest("CA certificate is served"):
        test_cache_ca_cert()

    with subtest("Cache can reach registry"):
        test_cache_reaches_registry()

    with subtest("Client Docker configuration"):
        test_client_docker_config()

    with subtest("Pull image through cache"):
        test_client_pull()

    with subtest("Image runs correctly"):
        test_image_works()

    print("All Docker cache integration tests passed!")
  '';
}
