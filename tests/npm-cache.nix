{
  pkgs,
  lib,
  ...
}:
let
  # Create a fake npm registry server for testing
  fakeNpmScript = pkgs.writeScriptBin "fake-npm" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import socketserver
    import json
    import logging

    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger('fake-npm')

    PORT = 8080

    # Fake package metadata
    PACKAGE_METADATA = {
        "name": "test-package",
        "description": "A test package",
        "dist-tags": {
            "latest": "1.0.0"
        },
        "versions": {
            "1.0.0": {
                "name": "test-package",
                "version": "1.0.0",
                "description": "A test package",
                "dist": {
                    "tarball": "http://localhost:8080/test-package/-/test-package-1.0.0.tgz",
                    "shasum": "abc123"
                }
            }
        }
    }

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            logger.info(format % args)

        def do_GET(self):
            path = self.path

            # Package metadata endpoint
            if path.startswith("/test-package"):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(PACKAGE_METADATA).encode())
                return

            # Package tarball endpoint
            if path.endswith(".tgz"):
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                self.wfile.write(b"FAKE_TARBALL_CONTENT")
                return

            # Health check
            if path == "/" or path == "/health":
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b"OK")
                return

            self.send_response(404)
            self.end_headers()

    def run_server():
        logger.info(f"Starting fake npm registry on port {PORT}")
        httpd = socketserver.TCPServer(("0.0.0.0", PORT), Handler)
        httpd.allow_reuse_address = True
        logger.info("Server started successfully")
        try:
            httpd.serve_forever()
        finally:
            httpd.server_close()

    if __name__ == '__main__':
        run_server()
  '';
in
pkgs.testers.nixosTest {
  name = "npm-cache";

  nodes = {
    # Fake npm registry
    npmreg =
      { config, pkgs, ... }:
      {
        networking.firewall.allowedTCPPorts = [ 8080 ];

        systemd.services.fake-npm = {
          description = "Fake npm Registry";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "${fakeNpmScript}/bin/fake-npm";
            DynamicUser = true;
            Restart = "always";
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      };

    # npm cache proxy
    cache =
      { config, pkgs, ... }:
      {
        imports = [ ../modules/npm-cache.nix ];

        modules.services.npm-cache = {
          enable = true;
          domain = "npm-cache.test";
          dataDir = "/var/lib/verdaccio";
          port = 4873;
          enableSSL = false;
        };

        # Configure Verdaccio to use our fake npm registry
        systemd.tmpfiles.rules = [
          "d /var/lib/verdaccio 0755 verdaccio verdaccio -"
        ];

        # Override verdaccio config to point to fake registry
        systemd.services.verdaccio = {
          preStart = lib.mkBefore ''
            cat > /var/lib/verdaccio/config.yaml <<EOF
            storage: /var/lib/verdaccio/storage
            plugins: /var/lib/verdaccio/plugins

            web:
              enable: true
              title: Test npm Cache

            uplinks:
              npmjs:
                url: http://npmreg:8080/
                timeout: 30s
                maxage: 10m
                cache: true

            packages:
              '@*/*':
                access: \$all
                publish: \$authenticated
                proxy: npmjs

              '**':
                access: \$all
                publish: \$authenticated
                proxy: npmjs

            server:
              keepAliveTimeout: 60

            listen: 127.0.0.1:4873

            log:
              type: stdout
              format: pretty
              level: warn
            EOF
            chown verdaccio:verdaccio /var/lib/verdaccio/config.yaml
          '';

          serviceConfig = {
            ExecStart = lib.mkForce "${pkgs.verdaccio}/bin/verdaccio --config /var/lib/verdaccio/config.yaml";
          };
        };
      };

    # Client using the cache
    client =
      { config, pkgs, ... }:
      {
        imports = [ ../behaviors/use-npm-cache.nix ];

        behaviors.npm-cache = {
          enable = true;
          cacheUrl = "http://npm-cache.test";
        };

        environment.systemPackages = with pkgs; [
          curl
          nodejs
        ];
      };
  };

  testScript = ''
    def test_upstream_connectivity():
        """Test connectivity to fake upstream npm registry"""
        npmreg.succeed("curl -f http://localhost:8080/")
        npmreg.succeed("curl -f http://localhost:8080/test-package")

    def test_cache_services():
        """Test cache services are running"""
        cache.wait_for_unit("verdaccio.service")
        cache.wait_for_unit("nginx.service")
        cache.wait_for_open_port(4873)
        cache.wait_for_open_port(80)

    def test_verdaccio_responding():
        """Test Verdaccio is responding"""
        cache.succeed("curl -f http://localhost:4873/")

    def test_nginx_proxy():
        """Test nginx is proxying to Verdaccio"""
        cache.succeed("curl -f http://localhost/")

    def test_npm_configuration():
        """Test npm is configured to use cache"""
        npmrc = client.succeed("cat /etc/npmrc")
        assert "npm-cache.test" in npmrc, "Cache URL not in npmrc"

    def test_package_proxy():
        """Test that package requests are proxied"""
        # Request package through cache
        result = cache.succeed("curl -f http://localhost/test-package")
        assert "test-package" in result, "Package metadata not returned"

    def test_cache_functionality():
        """Test that nginx caches responses"""
        # First request
        cache.succeed("curl -f http://localhost/test-package")

        # Wait for cache files
        cache.wait_until_succeeds("test $(find /var/cache/nginx/npm -type f | wc -l) -gt 0", timeout=10)

    def test_stale_serving():
        """Test that cache serves stale content when upstream is down"""
        # Populate cache
        cache.succeed("curl -f http://localhost/test-package")

        # Wait for caching
        cache.wait_until_succeeds("test $(find /var/cache/nginx/npm -type f | wc -l) -gt 0", timeout=10)

        # Stop upstream
        npmreg.succeed("systemctl stop fake-npm.service")
        npmreg.wait_until_fails("curl -f http://localhost:8080/", timeout=10)

        # Request should still work from cache
        cache.succeed("curl -f http://localhost/test-package")

        # Restart upstream
        npmreg.succeed("systemctl start fake-npm.service")
        npmreg.wait_for_unit("fake-npm.service")

    # Start all nodes
    start_all()

    # Wait for services
    npmreg.wait_for_unit("fake-npm.service")
    npmreg.wait_for_open_port(8080)

    # Run tests
    with subtest("Testing upstream connectivity"):
        test_upstream_connectivity()

    with subtest("Testing cache services"):
        test_cache_services()

    with subtest("Testing Verdaccio responding"):
        test_verdaccio_responding()

    with subtest("Testing nginx proxy"):
        test_nginx_proxy()

    with subtest("Testing npm configuration"):
        test_npm_configuration()

    with subtest("Testing package proxy"):
        test_package_proxy()

    with subtest("Testing cache functionality"):
        test_cache_functionality()

    with subtest("Testing stale serving"):
        test_stale_serving()

    print("All npm cache tests passed!")
  '';
}
