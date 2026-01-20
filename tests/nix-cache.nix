{
  pkgs,
  lib,
  ...
}:
let
  # Create a fake nix cache server that mimics cache.nixos.org
  fakeNixCacheScript = pkgs.writeScriptBin "fake-nix-cache" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import socketserver
    import logging

    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger('fake-nix-cache')

    PORT = 8080

    # Fake nix-cache-info content
    NIX_CACHE_INFO = """StoreDir: /nix/store
    WantMassQuery: 1
    Priority: 30
    """

    # Fake NAR info for a test path
    FAKE_NARINFO = """StorePath: /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test
    URL: nar/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.nar.xz
    Compression: xz
    FileHash: sha256:0000000000000000000000000000000000000000000000000000000000000000
    FileSize: 1234
    NarHash: sha256:0000000000000000000000000000000000000000000000000000000000000000
    NarSize: 5678
    References:
    """

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            logger.info(format % args)

        def do_GET(self):
            path = self.path

            if path == "/nix-cache-info":
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(NIX_CACHE_INFO.encode())
                return

            if path.endswith(".narinfo"):
                self.send_response(200)
                self.send_header('Content-Type', 'text/x-nix-narinfo')
                self.end_headers()
                self.wfile.write(FAKE_NARINFO.encode())
                return

            if path.startswith("/nar/"):
                self.send_response(200)
                self.send_header('Content-Type', 'application/x-nix-nar')
                self.end_headers()
                self.wfile.write(b"FAKE_NAR_CONTENT")
                return

            self.send_response(404)
            self.end_headers()

        def do_HEAD(self):
            path = self.path

            if path == "/nix-cache-info" or path.endswith(".narinfo"):
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                return

            self.send_response(404)
            self.end_headers()

    def run_server():
        logger.info(f"Starting fake Nix cache server on port {PORT}")
        with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
            logger.info("Server started successfully")
            httpd.serve_forever()

    if __name__ == '__main__':
        run_server()
  '';
in
pkgs.testers.nixosTest {
  name = "nix-cache";

  nodes = {
    # Fake nix cache server (simulating cache.nixos.org)
    upstream =
      { config, pkgs, ... }:
      {
        networking.firewall.allowedTCPPorts = [ 8080 ];

        systemd.services.fake-nix-cache = {
          description = "Fake Nix Cache Server";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "${fakeNixCacheScript}/bin/fake-nix-cache";
            DynamicUser = true;
            Restart = "always";
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      };

    # Nix cache proxy
    cache =
      { config, pkgs, ... }:
      {
        imports = [ ../modules/nix-cache.nix ];

        modules.services.nix-cache = {
          enable = true;
          domain = "nix-cache.test";
          cacheDir = "/var/cache/nix-proxy";
          maxCacheSize = "1g";
          upstreamEndpoint = "upstream:8080";
          upstreamProtocol = "http";
          enableSSL = false;
        };
      };

    # Client using the cache
    client =
      { config, pkgs, ... }:
      {
        imports = [ ../behaviors/use-nix-cache.nix ];

        behaviors.nix-cache = {
          enable = true;
          cacheUrl = "http://nix-cache.test";
          fallbackToUpstream = false;
        };

        environment.systemPackages = with pkgs; [
          curl
        ];
      };
  };

  testScript = ''
    def test_upstream_connectivity():
        """Test connectivity to fake upstream server"""
        upstream.succeed("curl -f http://localhost:8080/nix-cache-info")

    def test_cache_service():
        """Test Nix cache service is running"""
        cache.wait_for_unit("nginx.service")
        cache.wait_for_open_port(80)

        cache.succeed("curl -f http://localhost/nix-cache-info")

    def test_cache_directory():
        """Test cache directory structure"""
        cache.succeed("test -d /var/cache/nix-proxy")

    def test_nix_configuration():
        """Test Nix is configured to use cache"""
        nix_conf = client.succeed("cat /etc/nix/nix.conf")
        assert "nix-cache.test" in nix_conf, "Cache URL not in nix.conf"

    def test_cache_proxy_functionality():
        """Test that cache proxy works"""
        # First request - should proxy to upstream
        result = cache.succeed("curl -v http://localhost/nix-cache-info 2>&1")
        assert "StoreDir" in result, "nix-cache-info not returned"

        # Check cache status header
        cache.succeed("curl -I http://localhost/nix-cache-info 2>&1 | grep -i 'X-Cache-Status'")

    def test_cache_persistence():
        """Test that cache stores data"""
        # Make a request to cache something
        cache.succeed("curl -f http://localhost/nix-cache-info")

        # Wait for cache files
        cache.wait_until_succeeds("test $(find /var/cache/nix-proxy -type f | wc -l) -gt 0", timeout=10)

    def test_stale_serving():
        """Test that cache serves stale content when upstream is down"""
        # First request to populate cache
        cache.succeed("curl -f http://localhost/nix-cache-info")

        # Wait for caching
        cache.wait_until_succeeds("test $(find /var/cache/nix-proxy -type f | wc -l) -gt 0", timeout=10)

        # Stop upstream
        upstream.succeed("systemctl stop fake-nix-cache.service")
        upstream.wait_until_fails("curl -f http://localhost:8080/nix-cache-info", timeout=10)

        # Request should still work from cache
        cache.succeed("curl -f http://localhost/nix-cache-info")

        # Restart upstream for cleanup
        upstream.succeed("systemctl start fake-nix-cache.service")
        upstream.wait_for_unit("fake-nix-cache.service")

    # Start all nodes
    start_all()

    # Wait for services
    upstream.wait_for_unit("fake-nix-cache.service")
    upstream.wait_for_open_port(8080)

    # Run tests
    with subtest("Testing upstream connectivity"):
        test_upstream_connectivity()

    with subtest("Testing cache service"):
        test_cache_service()

    with subtest("Testing cache directory"):
        test_cache_directory()

    with subtest("Testing Nix configuration"):
        test_nix_configuration()

    with subtest("Testing cache proxy functionality"):
        test_cache_proxy_functionality()

    with subtest("Testing cache persistence"):
        test_cache_persistence()

    with subtest("Testing stale serving"):
        test_stale_serving()

    print("All Nix cache tests passed!")
  '';
}
