{ lib, pkgs, writeShellScriptBin, python3 }:

# Lightweight Verdaccio mock for testing
# This is a simple HTTP server that proxies npm registry requests
writeShellScriptBin "verdaccio" ''
  exec ${python3}/bin/python3 ${pkgs.writeText "verdaccio-mock.py" ''
    #!/usr/bin/env python3
    import http.server
    import socketserver
    import urllib.request
    import urllib.error
    import sys
    import json
    import re
    from pathlib import Path

    class VerdaccioHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):
            sys.stderr.write("[verdaccio] %s\n" % (format % args))

        def do_GET(self):
            # Proxy requests to upstream (configured via environment or use default)
            upstream = "https://registry.npmjs.org"

            # Check config file for upstream URL
            config_path = sys.argv[2] if len(sys.argv) > 2 else None
            if config_path and Path(config_path).exists():
                with open(config_path) as f:
                    for line in f:
                        if 'url:' in line and 'uplinks' in open(config_path).read()[:open(config_path).read().find(line)]:
                            match = re.search(r'url:\s*(.+)', line)
                            if match:
                                upstream = match.group(1).strip()
                                break

            url = upstream + self.path
            self.log_message("Proxying GET %s", url)

            try:
                with urllib.request.urlopen(url, timeout=30) as response:
                    self.send_response(response.status)
                    for header, value in response.headers.items():
                        if header.lower() not in ['transfer-encoding', 'connection']:
                            self.send_header(header, value)
                    self.end_headers()
                    self.wfile.write(response.read())
            except urllib.error.HTTPError as e:
                self.send_response(e.code)
                self.end_headers()
                self.wfile.write(e.read())
            except Exception as e:
                self.log_message("Error: %s", str(e))
                self.send_response(502)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())

    # Parse listen address from config or use default
    host = "127.0.0.1"
    port = 4873

    config_path = None
    for i, arg in enumerate(sys.argv):
        if arg == "--config" and i + 1 < len(sys.argv):
            config_path = sys.argv[i + 1]
            break

    if config_path and Path(config_path).exists():
        with open(config_path) as f:
            for line in f:
                if 'listen:' in line:
                    match = re.search(r'listen:\s*(.+):(\d+)', line)
                    if match:
                        host = match.group(1).strip()
                        port = int(match.group(2))

    print(f"Starting Verdaccio mock on {host}:{port}")
    with socketserver.TCPServer((host, port), VerdaccioHandler) as httpd:
        httpd.allow_reuse_address = True
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down...")
  ''} "$@"
''
