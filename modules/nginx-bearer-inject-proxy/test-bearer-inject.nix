{ pkgs, ... }:

let
  bearerModule = import ./default.nix;

  realSecretPath = "/run/test-secrets/api-key";
in
pkgs.testers.nixosTest {
  name = "nginx-bearer-inject-proxy-test";

  nodes.server =
    { config, ... }:
    {
      imports = [ bearerModule ];

      systemd.services.fake-secret = {
        description = "Write a runtime-only fake bearer for the test";
        before = [ "nginx-bearer-inject.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          install -d -m 0700 /run/test-secrets
          if [ ! -s ${realSecretPath} ]; then
            umask 077
            printf 'FAKEKEY-%s' \
              "$(${pkgs.coreutils}/bin/head -c 18 /dev/urandom \
                | ${pkgs.coreutils}/bin/base64 \
                | ${pkgs.gnused}/bin/sed 's/[^a-zA-Z0-9]//g' \
                | ${pkgs.coreutils}/bin/head -c 32)" > ${realSecretPath}
          fi
        '';
      };

      services.nginxBearerInject.injectors = {
        real = {
          mode = "real";
          secretFile = realSecretPath;
          keyPrefix = "sk-";
        };
        passthrough = {
          mode = "passthrough";
        };
      };

      services.nginx = {
        enable = true;
        virtualHosts."localhost" = {
          locations."/real/" = {
            proxyPass = "http://127.0.0.1:9/";
            extraConfig = "include ${config.services.nginxBearerInject.injectors.real.snippetPath};";
          };
          locations."/passthrough/" = {
            proxyPass = "http://127.0.0.1:9/";
            extraConfig = "include ${config.services.nginxBearerInject.injectors.passthrough.snippetPath};";
          };
        };
      };

      virtualisation = {
        memorySize = 1024;
        diskSize = 2048;
      };
    };

  testScript = ''
    import re

    real_snip = "/run/nginx-snippets/bearer-real.conf"
    pass_snip = "/run/nginx-snippets/bearer-passthrough.conf"

    start_all()
    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("nginx.service")

    with subtest("(d) nginx started with the snippets included"):
        server.succeed("systemctl is-active nginx")

    with subtest("(a) the real snippet exists at mode 0640"):
        server.succeed(f"test -f {real_snip}")
        mode = server.succeed(f"stat -c '%a' {real_snip}").strip()
        assert mode == "640", f"expected mode 0640, got {mode}"

    with subtest("the real bearer value was injected into the snippet"):
        secret = server.succeed("cat /run/test-secrets/api-key").strip()
        assert secret, "fake secret file is empty"
        snip = server.succeed(f"cat {real_snip}")
        assert secret in snip, snip
        assert "Bearer sk-" in snip, snip

    with subtest("(b) the secret VALUE is nowhere under /nix/store"):
        # grep exits 0 on a hit, 1 on clean, >1 on error; a clean tree is the
        # only pass. The value is [A-Za-z0-9-] only, so it is safe single-quoted.
        rc, out = server.execute(f"grep -rlF -- '{secret}' /nix/store")
        assert rc != 0, f"secret leaked into the store:\n{out}"

    with subtest("(c) passthrough produced a non-empty token snippet at 0640"):
        server.succeed(f"test -f {pass_snip}")
        pmode = server.succeed(f"stat -c '%a' {pass_snip}").strip()
        assert pmode == "640", f"expected passthrough mode 0640, got {pmode}"
        ptext = server.succeed(f"cat {pass_snip}")
        m = re.search(r'Bearer (\S+)"', ptext)
        assert m and len(m.group(1)) > 0, f"no non-empty passthrough token: {ptext!r}"

    print("ALL CHECKS PASSED")
  '';
}
