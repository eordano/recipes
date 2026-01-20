{
  pkgs,
  lib,
  ...
}:
let
  # Create a minimal valid npm package
  testPackageJson = pkgs.writeText "package.json" (builtins.toJSON {
    name = "test-package";
    version = "1.0.0";
    description = "A test package for npm cache testing";
    main = "index.js";
    keywords = [ "test" ];
    author = "Test Author";
    license = "MIT";
  });

  testPackageIndex = pkgs.writeText "index.js" ''
    module.exports = { hello: function() { return "Hello from test-package!"; } };
  '';

  # Create a proper npm package tarball (gzipped tar with package/ prefix)
  testPackageTarball = pkgs.runCommand "test-package-1.0.0.tgz" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
  } ''
    mkdir -p package
    cp ${testPackageJson} package/package.json
    cp ${testPackageIndex} package/index.js
    tar -czf $out package
  '';

  # Calculate the shasum of the tarball at build time
  testPackageShasum = pkgs.runCommand "test-package-shasum" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    sha1sum ${testPackageTarball} | cut -d' ' -f1 > $out
  '';

  # Create a fake npm registry server that serves real package data
  fakeNpmScript = pkgs.writeScriptBin "fake-npm" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import socketserver
    import json
    import logging
    import os

    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger('fake-npm')

    PORT = 8080
    TARBALL_PATH = "${testPackageTarball}"

    # Read the shasum from the file generated at build time
    with open("${testPackageShasum}", "r") as f:
        PACKAGE_SHASUM = f.read().strip()

    logger.info(f"Package tarball: {TARBALL_PATH}")
    logger.info(f"Package shasum: {PACKAGE_SHASUM}")

    # Real package metadata with correct shasum
    PACKAGE_METADATA = {
        "name": "test-package",
        "description": "A test package for npm cache testing",
        "dist-tags": {
            "latest": "1.0.0"
        },
        "versions": {
            "1.0.0": {
                "name": "test-package",
                "version": "1.0.0",
                "description": "A test package for npm cache testing",
                "main": "index.js",
                "keywords": ["test"],
                "author": "Test Author",
                "license": "MIT",
                "dist": {
                    "tarball": "http://npmreg:8080/test-package/-/test-package-1.0.0.tgz",
                    "shasum": PACKAGE_SHASUM
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
            if path == "/test-package" or path.startswith("/test-package?"):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(PACKAGE_METADATA).encode())
                return

            # Package tarball endpoint
            if path.endswith(".tgz"):
                try:
                    with open(TARBALL_PATH, "rb") as f:
                        tarball_data = f.read()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str(len(tarball_data)))
                    self.end_headers()
                    self.wfile.write(tarball_data)
                    logger.info(f"Served tarball: {len(tarball_data)} bytes")
                except Exception as e:
                    logger.error(f"Error serving tarball: {e}")
                    self.send_response(500)
                    self.end_headers()
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
        socketserver.TCPServer.allow_reuse_address = True
        httpd = socketserver.TCPServer(("0.0.0.0", PORT), Handler)
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

        networking.firewall.allowedTCPPorts = [ 80 ];

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

        networking.extraHosts = ''
          192.168.1.1 npm-cache.test
        '';

        behaviors.npm-cache = {
          enable = true;
          cacheUrl = "http://npm-cache.test";
          strictSsl = false;
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

    def test_tarball_served():
        """Test that the tarball is served correctly"""
        result = npmreg.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/test-package/-/test-package-1.0.0.tgz")
        assert result.strip() == "200", f"Tarball not served: HTTP {result}"

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

    def test_package_proxy():
        """Test that package requests are proxied"""
        # Request package through cache
        result = cache.succeed("curl -f http://localhost/test-package")
        assert "test-package" in result, "Package metadata not returned"

    def test_npm_install():
        """Test that npm install actually works through the cache"""
        # Create a test project directory
        client.succeed("mkdir -p /tmp/test-project")
        client.succeed("cd /tmp/test-project && echo '{}' > package.json")

        # Install the test package through the cache
        # Use --registry explicitly and disable strict SSL for test environment
        client.succeed(
            "cd /tmp/test-project && npm install test-package --registry=http://npm-cache.test --no-strict-ssl 2>&1"
        )

        # Verify the package was installed
        client.succeed("test -d /tmp/test-project/node_modules/test-package")
        client.succeed("test -f /tmp/test-project/node_modules/test-package/package.json")
        client.succeed("test -f /tmp/test-project/node_modules/test-package/index.js")

        # Verify package.json content
        pkg_json = client.succeed("cat /tmp/test-project/node_modules/test-package/package.json")
        assert '"name": "test-package"' in pkg_json or '"name":"test-package"' in pkg_json, \
            f"Package name not found in package.json: {pkg_json}"

    def test_npm_require():
        """Test that the installed package can be required"""
        client.succeed(
            "cd /tmp/test-project && node -e \"const pkg = require('test-package'); console.log(pkg.hello());\""
        )

    def test_stale_serving():
        """Test that cache serves stale content when upstream is down"""
        # Populate cache
        cache.succeed("curl -f http://localhost/test-package")

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

    with subtest("Testing tarball is served"):
        test_tarball_served()

    with subtest("Testing cache services"):
        test_cache_services()

    with subtest("Testing Verdaccio responding"):
        test_verdaccio_responding()

    with subtest("Testing nginx proxy"):
        test_nginx_proxy()

    with subtest("Testing package proxy"):
        test_package_proxy()

    with subtest("Testing npm install"):
        test_npm_install()

    with subtest("Testing npm require"):
        test_npm_require()

    with subtest("Testing stale serving"):
        test_stale_serving()

    print("All npm cache tests passed!")
  '';
}
