{ pkgs, ... }:

let
  coiModule = import ./default.nix;

  appBundle = pkgs.runCommand "coi-wasm-bundle" { } ''
    mkdir -p "$out/assets"
    printf '<!doctype html><title>coi app</title><script src="/app/assets/main.abcd1234.js"></script>' > "$out/index.html"
    printf 'export const MARKER="ASSET_OK";' > "$out/assets/main.abcd1234.js"
    ${pkgs.brotli}/bin/brotli -q 5 -c "$out/assets/main.abcd1234.js" > "$out/assets/main.abcd1234.js.br"
    printf '\0asm\1\0\0\0' > "$out/assets/engine.abcd1234.wasm"
    ${pkgs.brotli}/bin/brotli -q 5 -c "$out/assets/engine.abcd1234.wasm" > "$out/assets/engine.abcd1234.wasm.br"
  '';
in
pkgs.testers.nixosTest {
  name = "nginx-cross-origin-isolated-wasm-test";

  nodes.server =
    { ... }:
    {
      imports = [ coiModule ];

      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;

        virtualHosts."localhost" = {
          extraConfig = ''
            add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
          '';
          crossOriginIsolatedApps."/app" = {
            root = appBundle;
            immutablePaths = [ "assets" ];
            contentSecurityPolicy = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:";
            apiProxy."/app/api" = "http://127.0.0.1:8080/v1";
          };
        };

        virtualHosts."echo-upstream" = {
          listen = [
            {
              addr = "127.0.0.1";
              port = 8080;
            }
          ];
          locations."/" = {
            extraConfig = ''
              default_type text/plain;
              return 200 "upstream_saw=$request_uri";
            '';
          };
        };
      };
    };

  testScript = ''
    server.wait_for_unit("nginx.service")
    server.wait_for_open_port(80)

    print("[1/7] the bare mount 308-redirects to the trailing-slash form")
    redirect = server.succeed("curl -si http://localhost/app")
    assert "308" in redirect, redirect
    assert "location: /app/" in redirect.lower(), redirect

    print("[2/7] the entrypoint carries COOP/COEP/CORP and is no-cache")
    idx = server.succeed("curl -si http://localhost/app/")
    assert "cross-origin-opener-policy: same-origin" in idx.lower(), idx
    assert "cross-origin-embedder-policy: credentialless" in idx.lower(), idx
    assert "cross-origin-resource-policy: same-origin" in idx.lower(), idx
    assert "cache-control: no-cache" in idx.lower(), idx

    print("[3/7] TRAP: the location re-emits server-level HSTS (add_header replaces, not appends)")
    assert "strict-transport-security: max-age=63072000" in idx.lower(), idx
    assert "content-security-policy:" in idx.lower(), idx

    print("[4/7] content-hashed asset is immutable AND still carries the COI headers")
    asset = server.succeed("curl -si http://localhost/app/assets/main.abcd1234.js")
    assert "cache-control: public, max-age=31536000, immutable" in asset.lower(), asset
    assert "cross-origin-embedder-policy: credentialless" in asset.lower(), asset
    assert "strict-transport-security:" in asset.lower(), asset

    print("[5/7] brotli_static serves the precompressed .br sidecar")
    br = server.succeed("curl -si -H 'Accept-Encoding: br' http://localhost/app/assets/main.abcd1234.js")
    assert "content-encoding: br" in br.lower(), br

    print("[6/7] SPA deep link falls back to the entrypoint")
    deep = server.succeed("curl -s http://localhost/app/some/client/route")
    assert "coi app" in deep, deep

    print("[7/7] TRAP: apiProxy exact-match strips the public prefix before forwarding upstream")
    api = server.succeed("curl -s http://localhost/app/api")
    # The public call is /app/api; the echo upstream must report /v1, proving the
    # prefix was stripped (not forwarded as /app/api or /v1/app/api).
    assert "upstream_saw=/v1" in api, api
    assert "/app/api" not in api, api

    print("ALL CHECKS PASSED")
  '';
}
