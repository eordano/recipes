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

  # Generate TLS certificates for the upstream registry
  certs = pkgs.runCommand "docker-registry-certs" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out

    # Generate CA
    openssl genrsa -out $out/ca.key 2048
    openssl req -new -x509 -days 3650 -key $out/ca.key -out $out/ca.crt \
      -subj "/CN=test-docker-registry-ca/O=Test/C=US"

    # Generate server cert with SANs for both registry and localhost
    openssl genrsa -out $out/server.key 2048

    # Create a config file for SANs
    cat > $out/openssl.cnf <<EOF
    [req]
    distinguished_name = req_distinguished_name
    req_extensions = v3_req

    [req_distinguished_name]
    CN = registry

    [v3_req]
    subjectAltName = @alt_names

    [alt_names]
    DNS.1 = registry
    DNS.2 = localhost
    IP.1 = 127.0.0.1
    IP.2 = 192.168.1.3
    EOF

    openssl req -new -key $out/server.key -out $out/server.csr \
      -subj "/CN=registry/O=Test/C=US" -config $out/openssl.cnf

    openssl x509 -req -days 3650 -in $out/server.csr \
      -CA $out/ca.crt -CAkey $out/ca.key -CAcreateserial \
      -out $out/server.crt -extensions v3_req -extfile $out/openssl.cnf

    rm $out/server.csr $out/ca.srl $out/openssl.cnf 2>/dev/null || true
  '';
in
pkgs.testers.nixosTest {
  name = "docker-cache";

  nodes = {
    # Upstream Docker registry with TLS
    registry =
      { config, pkgs, ... }:
      {
        services.dockerRegistry = {
          enable = true;
          listenAddress = "0.0.0.0";
          port = 5000;
          extraConfig = {
            http.tls = {
              certificate = "${certs}/server.crt";
              key = "${certs}/server.key";
            };
          };
        };

        # Trust our test CA for local operations
        security.pki.certificateFiles = [ "${certs}/ca.crt" ];

        virtualisation.docker.enable = true;
        # Docker needs to trust the registry's TLS cert
        environment.etc."docker/certs.d/localhost:5000/ca.crt".source = "${certs}/ca.crt";

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

        # Trust our test CA
        security.pki.certificateFiles = [ "${certs}/ca.crt" ];

        modules.services.docker-cache = {
          enable = true;
          domain = "cache";
          acmeHost = "test";
          enableSSL = false;
          cacheDir = "/var/cache/docker-registry-proxy";
          maxSize = "5g";
          # Use IP address directly since the container's internal nginx resolver
          # doesn't use /etc/hosts (--add-host). NixOS test VMs get IPs in
          # alphabetical order: cache=.1, client=.2, registry=.3
          registries = [ "192.168.1.3:5000" ];
        };

        # Mount the CA certificate so the container trusts the upstream registry's TLS.
        # The registry is specified by IP address directly, so no --add-host needed.
        virtualisation.oci-containers.containers.docker-registry-proxy.extraOptions = lib.mkForce [
          "--add-host=docker-registry-proxy:127.0.0.1"
          "-v" "${certs}/ca.crt:/usr/local/share/ca-certificates/test-ca.crt:ro"
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

        # Trust our test CA for system-wide TLS verification
        security.pki.certificateFiles = [ "${certs}/ca.crt" ];

        # Docker needs to trust the registry's TLS cert for direct connections
        # Using IP address since that's how the proxy is configured
        environment.etc."docker/certs.d/192.168.1.3:5000/ca.crt".source = "${certs}/ca.crt";

        # Disable IPv6 so Docker connects to the cache proxy via IPv4
        # (rpardini only listens on 0.0.0.0, not [::])
        networking.enableIPv6 = false;

        behaviors.docker-cache = {
          enable = true;
          cacheUrl = "http://cache";
        };
      };
  };

  testScript = ''
    def test_registry_service():
        """Test the Docker registry is running and healthy on HTTPS"""
        registry.wait_for_unit("docker-registry.service")
        registry.wait_for_open_port(5000)
        # Verify registry responds on HTTPS (not HTTP)
        registry.succeed("curl -f https://localhost:5000/v2/")
        # Verify HTTP is not available
        registry.fail("curl -f http://localhost:5000/v2/")

    def test_push_image():
        """Push the test image to the registry using Docker"""
        registry.wait_for_unit("docker.service")
        registry.succeed("${testImage} | docker load")
        registry.succeed("docker tag test-image:latest localhost:5000/test-image:latest")
        registry.succeed("docker push localhost:5000/test-image:latest")
        result = registry.succeed("curl -f https://localhost:5000/v2/_catalog")
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
        """Test the cache node can reach the registry over HTTPS"""
        cache.succeed("curl -f https://registry:5000/v2/")

    def test_client_docker_config():
        """Test client Docker has proxy settings"""
        client.wait_for_unit("docker.service")
        info = client.succeed("docker info")
        assert "cache" in info or "3128" in info, \
            f"Proxy config not in docker info: {info}"

    def test_client_pull():
        """Pull the test image from registry through the cache proxy"""
        # Use IP address to match the proxy's registry configuration
        client.succeed("docker pull 192.168.1.3:5000/test-image:latest")

    def test_pull_went_through_proxy():
        """Verify the pull actually went through the cache proxy"""
        # Check the cache proxy logs for evidence of the request
        # The registry is configured by IP (192.168.1.3:5000) so we check for that
        logs = cache.succeed("docker logs docker-registry-proxy 2>&1")
        assert "192.168.1.3:5000" in logs, \
            f"Cache proxy logs don't show 192.168.1.3:5000 traffic: {logs}"

    def test_image_works():
        """Verify the pulled image exists and runs"""
        result = client.succeed("docker images --format '{{.Repository}}:{{.Tag}}'")
        assert "192.168.1.3:5000/test-image:latest" in result, \
            f"Image not found: {result}"
        client.succeed("docker run --rm 192.168.1.3:5000/test-image:latest /bin/true")

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

    with subtest("Pull went through proxy"):
        test_pull_went_through_proxy()

    with subtest("Image runs correctly"):
        test_image_works()

    print("All Docker cache integration tests passed!")
  '';
}
