{
  pkgs,
  lib,
  ...
}:
let
  # Create a fake Hugging Face server for testing
  fakeHfScript = pkgs.writeScriptBin "fake-hf" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import socketserver
    import json
    import logging

    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger('fake-hf')

    PORT = 8080

    # Fake model data
    MODEL_INFO = {
        "id": "bert-base-uncased",
        "modelId": "bert-base-uncased",
        "sha": "abc123",
        "pipeline_tag": "fill-mask",
        "library_name": "transformers"
    }

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            logger.info(format % args)

        def do_GET(self):
            path = self.path

            # API endpoints
            if path.startswith("/api/models/"):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(MODEL_INFO).encode())
                return

            # Model file download
            if "/resolve/" in path or "/raw/" in path:
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                self.wfile.write(b"FAKE_MODEL_CONTENT_" + path.encode())
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

        def do_HEAD(self):
            path = self.path

            if path.startswith("/api/") or "/resolve/" in path or "/raw/" in path:
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                return

            self.send_response(404)
            self.end_headers()

    def run_server():
        logger.info(f"Starting fake Hugging Face server on port {PORT}")
        with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
            logger.info("Server started successfully")
            httpd.serve_forever()

    if __name__ == '__main__':
        run_server()
  '';
in
pkgs.testers.nixosTest {
  name = "huggingface-cache";

  nodes = {
    # Fake Hugging Face server
    upstream =
      { config, pkgs, ... }:
      {
        networking.firewall.allowedTCPPorts = [ 8080 ];

        systemd.services.fake-hf = {
          description = "Fake Hugging Face Server";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "${fakeHfScript}/bin/fake-hf";
            DynamicUser = true;
            Restart = "always";
          };
        };
      };

    # Hugging Face cache proxy
    cache =
      { config, pkgs, ... }:
      {
        imports = [ ../modules/huggingface-cache.nix ];

        modules.services.huggingface-cache = {
          enable = true;
          domain = "hf-cache.test";
          cacheDir = "/var/cache/huggingface";
          maxSize = "1g";
          upstream = "upstream:8080";
          upstreamProtocol = "http";
          enableSSL = false;
          resolver = null;  # No DNS resolver needed for static upstream
        };
      };

    # Client using the cache
    client =
      { config, pkgs, ... }:
      {
        imports = [ ../behaviors/use-huggingface-cache.nix ];

        behaviors.huggingface-cache = {
          enable = true;
          endpoint = "http://hf-cache.test";
        };

        environment.systemPackages = with pkgs; [
          curl
        ];
      };
  };

  testScript = ''
    def test_upstream_connectivity():
        """Test connectivity to fake upstream server"""
        upstream.succeed("curl -f http://localhost:8080/")
        upstream.succeed("curl -f http://localhost:8080/api/models/bert-base-uncased")

    def test_cache_service():
        """Test HF cache service is running"""
        cache.wait_for_unit("nginx.service")
        cache.wait_for_open_port(80)

        cache.succeed("curl -f http://localhost/")

    def test_cache_directory():
        """Test cache directory structure"""
        cache.succeed("test -d /var/cache/huggingface")

    def test_hf_endpoint_configuration():
        """Test HF endpoint is configured"""
        env_vars = client.succeed("env | grep -i hf || true")
        assert "HF_ENDPOINT" in env_vars or "HUGGINGFACE" in env_vars, "HF endpoint not configured"

    def test_cache_proxy_functionality():
        """Test that cache proxy works"""
        # Test model API
        result = cache.succeed("curl -v http://localhost/api/models/bert-base-uncased 2>&1")
        assert "bert-base-uncased" in result, "Model API not working"

        # Check cache status header
        cache.succeed("curl -I http://localhost/api/models/bert-base-uncased 2>&1 | grep -i 'X-Cache-Status'")

    def test_model_file_caching():
        """Test that model files are cached"""
        # Download a model file
        cache.succeed("curl -f http://localhost/bert-base-uncased/resolve/main/config.json -o /tmp/config.json")

        # Wait for caching
        cache.wait_until_succeeds("test $(find /var/cache/huggingface -type f | wc -l) -gt 0", timeout=10)

    def test_stale_serving():
        """Test that cache serves stale content when upstream is down"""
        # First request to populate cache
        cache.succeed("curl -f http://localhost/api/models/bert-base-uncased")

        # Wait for caching
        cache.wait_until_succeeds("test $(find /var/cache/huggingface -type f | wc -l) -gt 0", timeout=10)

        # Stop upstream
        upstream.succeed("systemctl stop fake-hf.service")
        upstream.wait_until_fails("curl -f http://localhost:8080/", timeout=10)

        # Request should still work from cache
        cache.succeed("curl -f http://localhost/api/models/bert-base-uncased")

        # Restart upstream
        upstream.succeed("systemctl start fake-hf.service")
        upstream.wait_for_unit("fake-hf.service")

    # Start all nodes
    start_all()

    # Wait for services
    upstream.wait_for_unit("fake-hf.service")
    upstream.wait_for_open_port(8080)

    # Run tests
    with subtest("Testing upstream connectivity"):
        test_upstream_connectivity()

    with subtest("Testing cache service"):
        test_cache_service()

    with subtest("Testing cache directory"):
        test_cache_directory()

    with subtest("Testing HF endpoint configuration"):
        test_hf_endpoint_configuration()

    with subtest("Testing cache proxy functionality"):
        test_cache_proxy_functionality()

    with subtest("Testing model file caching"):
        test_model_file_caching()

    with subtest("Testing stale serving"):
        test_stale_serving()

    print("All Hugging Face cache tests passed!")
  '';
}
