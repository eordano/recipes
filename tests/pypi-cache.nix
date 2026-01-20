{
  pkgs,
  lib,
  ...
}:
let
  # Create a simple fake PyPI server for testing
  fakePypiScript = pkgs.writeScriptBin "fake-pypi" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import socketserver
    import json
    import logging
    from urllib.parse import urlparse

    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger('fake-pypi')

    PORT = 8080

    # Fake package metadata
    PACKAGES = {
        "requests": {
            "info": {
                "name": "requests",
                "version": "2.31.0",
                "summary": "Python HTTP for Humans."
            },
            "releases": {
                "2.31.0": [
                    {
                        "filename": "requests-2.31.0-py3-none-any.whl",
                        "url": "http://pypi:8080/packages/requests-2.31.0-py3-none-any.whl",
                        "digests": {
                            "sha256": "fakehash123456"
                        }
                    }
                ]
            }
        }
    }

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            logger.info(format % args)

        def do_GET(self):
            parsed_path = urlparse(self.path)
            path = parsed_path.path

            # Simple API endpoint
            if path == "/simple/":
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.end_headers()
                html = "<html><body>"
                for pkg in PACKAGES:
                    html += f'<a href="/simple/{pkg}/">{pkg}</a><br>'
                html += "</body></html>"
                self.wfile.write(html.encode())
                return

            # Package listing
            if path.startswith("/simple/") and path.endswith("/"):
                pkg_name = path.split("/")[2]
                if pkg_name in PACKAGES:
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html')
                    self.end_headers()
                    html = f"<html><body><h1>{pkg_name}</h1>"
                    for version, releases in PACKAGES[pkg_name]["releases"].items():
                        for release in releases:
                            html += f'<a href="{release["url"]}">{release["filename"]}</a><br>'
                    html += "</body></html>"
                    self.wfile.write(html.encode())
                    return

            # JSON API endpoint
            if path.startswith("/pypi/") and path.endswith("/json"):
                pkg_name = path.split("/")[2]
                if pkg_name in PACKAGES:
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps(PACKAGES[pkg_name]).encode())
                    return

            # Fake package download
            if path.startswith("/packages/"):
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                self.wfile.write(b"FAKE_WHEEL_CONTENT")
                return

            self.send_response(404)
            self.end_headers()

        def do_HEAD(self):
            parsed_path = urlparse(self.path)
            path = parsed_path.path

            if path == "/simple/" or (path.startswith("/simple/") and path.endswith("/")):
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.end_headers()
                return

            if path.startswith("/packages/"):
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(b"FAKE_WHEEL_CONTENT")))
                self.end_headers()
                return

            self.send_response(404)
            self.end_headers()

    def run_server():
        logger.info(f"Starting fake PyPI server on port {PORT}")
        with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
            logger.info("Server started successfully")
            httpd.serve_forever()

    if __name__ == '__main__':
        run_server()
  '';
in
pkgs.testers.nixosTest {
  name = "pypi-cache";

  nodes = {
    # Fake PyPI server
    pypi =
      { config, pkgs, ... }:
      {
        networking.firewall.allowedTCPPorts = [ 8080 ];

        systemd.services.fake-pypi = {
          description = "Fake PyPI Server";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "${fakePypiScript}/bin/fake-pypi";
            DynamicUser = true;
            Restart = "always";
          };
        };
      };

    # PyPI cache proxy
    cache =
      { config, pkgs, ... }:
      {
        imports = [ ../modules/pypi-cache.nix ];

        networking.firewall.allowedTCPPorts = [ 80 ];

        modules.services.pypi-cache = {
          enable = true;
          domain = "pypi-cache.test";
          dataDir = "/var/cache/pypi";
          port = 1326;
          enableSSL = false;
        };

        # Configure proxpi to use our fake PyPI
        systemd.services.pypi-cache.environment = {
          PROXPI_INDEX_URL = lib.mkForce "http://pypi:8080/simple/";
          PROXPI_CACHE_SIZE = lib.mkForce "104857600";
        };
      };

    # Client using the cache
    client =
      { config, pkgs, ... }:
      {
        imports = [ ../behaviors/use-pypi-cache.nix ];

        behaviors.pypi-cache = {
          enable = true;
          cacheUrl = "http://pypi-cache.test/index/";
          trustedHost = "pypi-cache.test";
        };

        environment.systemPackages = with pkgs; [
          (python3.withPackages (ps: [ ps.pip ]))
          curl
        ];
      };
  };

  testScript = ''
    def test_pypi_connectivity():
        """Test connectivity to fake PyPI server"""
        pypi.succeed("curl -f http://localhost:8080/simple/")
        pypi.succeed("curl -f http://localhost:8080/simple/requests/")

    def test_cache_service():
        """Test PyPI cache service is running"""
        cache.wait_for_unit("pypi-cache.service")
        cache.wait_for_unit("nginx.service")
        cache.wait_for_open_port(1326)
        cache.wait_for_open_port(80)

        cache.succeed("systemctl is-active pypi-cache.service")
        cache.succeed("curl -f http://localhost/")

    def test_cache_proxy_functionality():
        """Test that cache proxy works"""
        cache.succeed("curl -v http://localhost:1326/index/ 2>&1")
        cache.succeed("curl -f http://localhost:1326/index/requests/")

    def test_security_hardening():
        """Test service runs correctly with security hardening enabled"""
        # Verify service is running (proves hardening doesn't break it)
        cache.succeed("systemctl is-active pypi-cache.service")

        # Verify the service can still serve requests (functional test)
        cache.succeed("curl -f http://localhost:1326/index/")

    # Start all nodes
    start_all()

    # Wait for services
    pypi.wait_for_unit("fake-pypi.service")
    pypi.wait_for_open_port(8080)

    # Run tests
    with subtest("Testing PyPI connectivity"):
        test_pypi_connectivity()

    with subtest("Testing cache service"):
        test_cache_service()

    with subtest("Testing cache proxy functionality"):
        test_cache_proxy_functionality()

    with subtest("Testing security hardening"):
        test_security_hardening()

    print("All PyPI cache tests passed!")
  '';
}
