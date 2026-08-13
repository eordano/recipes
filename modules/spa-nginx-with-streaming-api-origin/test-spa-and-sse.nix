{ pkgs, ... }:

let
  spaStreamingModule = import ./default.nix;

  spa = pkgs.runCommand "spa" { } ''
    mkdir -p $out/assets
    echo 'console.log("app");' > $out/assets/app-abc123.js
    cat > $out/index.html <<'HTML'
    <!DOCTYPE html>
    <html><head>
      <script type="module" src="/assets/app-abc123.js"></script>
    </head><body><div id="root">SPA_SHELL_MARKER</div></body></html>
    HTML
  '';

  upstream = pkgs.writers.writePython3 "sse-upstream" { } ''
    import time
    from http.server import BaseHTTPRequestHandler, HTTPServer


    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/sse/"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                self.wfile.write(b"data: FIRST_EVENT\n\n")
                self.wfile.flush()
                time.sleep(30)
                return
            if self.path.startswith("/api/"):
                body = b'{"ok": true, "path": "%s"}' % self.path.encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.end_headers()

        def log_message(self, *a):
            pass


    HTTPServer(("127.0.0.1", 8080), H).serve_forever()
  '';

in
pkgs.testers.nixosTest {
  name = "spa-streaming-api-origin";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ spaStreamingModule ];

      systemd.services.sse-upstream = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${upstream}";
      };

      services.spaStreamingSites."example.com" = {
        default = true;
        root = spa;
        apiUpstreams = {
          "/api/".upstream = "http://127.0.0.1:8080";
          "/sse/".upstream = "http://127.0.0.1:8080";
        };
        extraVirtualHostConfig.locations."~ \\.json$".extraConfig = ''
          return 403;
        '';
      };

      environment.systemPackages = [ pkgs.curl ];
      networking.firewall.enable = false;
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("nginx.service", timeout=60)
    machine.wait_for_unit("sse-upstream.service", timeout=60)
    machine.wait_for_open_port(80)
    machine.wait_for_open_port(8080)

    with subtest("root serves the SPA shell"):
        out = machine.succeed("curl -s http://localhost/")
        assert "SPA_SHELL_MARKER" in out, out

    with subtest("a deep client-side route falls back to index.html (trap 1)"):
        # No file at /rooms/42/live on disk -> try_files must serve the SPA
        # entry document, NOT a 404, so the client-side router can take over.
        out = machine.succeed("curl -s http://localhost/rooms/42/live")
        assert "SPA_SHELL_MARKER" in out, out
        # And the shell references its asset by an ABSOLUTE URL, so that asset
        # still resolves when the shell was served for a deep path (trap 4).
        assert 'src="/assets/app-abc123.js"' in out, out

    with subtest("the absolute-based asset itself is served"):
        machine.succeed("curl -sf http://localhost/assets/app-abc123.js")

    with subtest("`^~ /api/` beats the regex `~ \\.json$` location (trap 2)"):
        # A plain-prefix /api/ would LOSE to the regex and return 403. `^~`
        # makes the prefix win, so the proxied JSON comes back 200.
        code = machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' http://localhost/api/data.json"
        )
        assert code == "200", f"expected 200 from proxied API, got {code}"
        body = machine.succeed("curl -s http://localhost/api/data.json")
        assert '"ok": true' in body, body

    with subtest("SSE is streamed, not buffered (trap 3)"):
        # The upstream flushes one event then holds the socket open for 30s.
        # With `proxy_buffering off`, a 3s-bounded read returns the first event.
        # With buffering ON, nginx would wait for the (never-arriving) end of
        # the response and the bounded read would return an EMPTY body.
        status, out = machine.execute(
            "curl -s --max-time 3 http://localhost/sse/stream"
        )
        assert "FIRST_EVENT" in out, (
            f"no event within the timeout -- nginx is BUFFERING the stream: {out!r}"
        )
        # curl exiting 28 (timeout) with the event already in hand is the
        # positive signal: the connection was live and streaming when we cut it.
        assert status != 0, "stream unexpectedly completed; upstream should hold it open"

    with subtest("negative control: buffering-off is why the event arrived early"):
        # Prove the early delivery is nginx streaming, not the upstream simply
        # finishing fast: talk to the upstream directly with the same bound and
        # confirm IT too only yields the first event within the window (i.e. the
        # 30s hold is real). If this returned a full/closed stream, the trap-3
        # assertion above would be meaningless.
        status, out = machine.execute(
            "curl -s --max-time 3 http://127.0.0.1:8080/sse/stream"
        )
        assert "FIRST_EVENT" in out and status != 0, (out, status)
  '';
}
