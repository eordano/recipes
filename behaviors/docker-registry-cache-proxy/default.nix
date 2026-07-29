# docker-registry-cache-proxy
#
# Point BOTH rootful and rootless Docker at an HTTP pull-through registry
# cache whose TLS is terminated with a self-signed CA. The whole trick is
# that the CA must be trusted BEFORE docker.service starts, and it must be
# installed under certs.d/ for the proxy host AND for both upstream Docker
# Hub hostnames (registry-1.docker.io and registry.docker.io), because the
# daemon consults certs.d/ keyed by the registry it thinks it is talking to.
#
# A oneshot fetches the CA over the network with a retry loop (the network
# may not be up yet when the unit runs) and installs it before Docker.
#
# Usage:
#   imports = [ ./docker-registry-cache-proxy ];
#   behaviors.docker-cache = {
#     enable   = true;
#     cacheUrl = "https://docker-cache.example.com"; # your pull-through cache
#     # proxyPort = 3128;                             # HTTP proxy port (default 3128)
#     # caCertPath = "/ca.crt";                       # path on cacheUrl serving the CA
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.behaviors.docker-cache;

  # Parse a "scheme://host[:port][/path]" URL into parts without importing
  # anything fleet-specific. Falls back to sane defaults on no match.
  parseUrl =
    url:
    let
      m = builtins.match "^(https?)://([^:/]+)(:([0-9]+))?(/.*)?$" url;
      scheme = if m != null then builtins.elemAt m 0 else "https";
      host = if m != null then builtins.elemAt m 1 else url;
      port =
        if m != null && builtins.elemAt m 3 != null then
          lib.toInt (builtins.elemAt m 3)
        else if scheme == "https" then
          443
        else
          80;
    in
    {
      inherit scheme host port;
    };
in
{
  options.behaviors.docker-cache = {
    enable = lib.mkEnableOption "Use a docker registry cache proxy";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://docker-cache.example.com";
      description = ''
        Base URL of the pull-through registry cache. Its self-signed CA is
        fetched from this host (see caCertPath) and trusted before Docker starts.
      '';
    };

    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 3128;
      description = ''
        Port on the cache host that speaks the Docker registry / HTTP proxy
        protocol. The Docker daemon is pointed at http://<cache-host>:<proxyPort>.
      '';
    };

    caCertPath = lib.mkOption {
      type = lib.types.str;
      default = "/ca.crt";
      description = "Path, relative to cacheUrl, that serves the cache's CA certificate.";
    };

    caCertSha256 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
      description = ''
        Optional lowercase-hex SHA-256 of the CA certificate PEM. When set, the
        downloaded CA is verified against this hash and installation fails closed
        on any mismatch. This pins the boot-time trust bootstrap so an on-path
        attacker who intercepts the (possibly plaintext) CA fetch cannot inject a
        CA that Docker would trust for the real Docker Hub hostnames. Leave null
        to keep the previous unpinned behavior.
      '';
    };

    maxAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "How many times the setup oneshot retries the CA download before failing.";
    };

    enableRootless = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also install the CA and proxy config for rootless Docker running inside
        per-user systemd sessions (writes ~/.config/docker and ~/.docker/config.json).
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      urlParts = parseUrl cfg.cacheUrl;

      cacheProtocol = urlParts.scheme;
      cacheDomain = urlParts.host;
      cachePort = urlParts.port;

      proxyPort = cfg.proxyPort;

      proxyUrl = "http://${cacheDomain}:${toString proxyPort}";
      caCertUrl = "${cacheProtocol}://${cacheDomain}${
        if cachePort == 443 || cachePort == 80 then "" else ":${toString cachePort}"
      }${cfg.caCertPath}";

      # certs.d directory names. The daemon looks up the CA by the registry
      # endpoint it addresses, so ALL THREE must be present:
      #   - the proxy host:port itself
      #   - registry-1.docker.io (the Docker Hub data endpoint)
      #   - registry.docker.io   (the Docker Hub auth/index endpoint)
      certsdHosts = [
        "${cacheDomain}:${toString proxyPort}"
        "registry-1.docker.io"
        "registry.docker.io"
      ];

      dockerDaemonConfig = {
        proxies = {
          "http-proxy" = proxyUrl;
          "https-proxy" = proxyUrl;
          "no-proxy" = "localhost,127.0.0.1";
        };
      };

      # Retry loop: on early boot the network may not be reachable even after
      # network-online.target, so keep trying instead of failing the boot.
      # The CA is staged in a per-invocation private temp file (mktemp: random
      # name, 0600) rather than a fixed world-writable /tmp path, so it is not a
      # cross-user pre-seed / symlink TOCTOU target on multi-user hosts. Callers
      # must set `CA_TMP="$(mktemp)"` (and rm it) around these snippets.
      downloadCaCert = ''
        max_attempts=${toString cfg.maxAttempts}
        attempt=0
        while [ $attempt -lt $max_attempts ]; do
          if ${pkgs.curl}/bin/curl -f -s -o "$CA_TMP" "${caCertUrl}"; then
            echo "Successfully downloaded CA certificate"
            break
          else
            attempt=$((attempt + 1))
            if [ $attempt -eq $max_attempts ]; then
              echo "Failed to download CA certificate from ${caCertUrl} after $max_attempts attempts"
              exit 1
            fi
            echo "Attempt $attempt/$max_attempts failed, retrying in 2 seconds..."
            sleep 2
          fi
        done${lib.optionalString (cfg.caCertSha256 != null) ''

        if ! echo "${cfg.caCertSha256}  $CA_TMP" | ${pkgs.coreutils}/bin/sha256sum -c - >/dev/null 2>&1; then
          echo "CA certificate SHA-256 mismatch (expected ${cfg.caCertSha256}) — refusing to install" >&2
          exit 1
        fi
        echo "CA certificate SHA-256 verified"''}'';

      installCa = target: ''
        ${pkgs.coreutils}/bin/install -m 644 "$CA_TMP" \
          ${target}'';

      installCaBundle = target: ''
        ${pkgs.coreutils}/bin/cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
          "$CA_TMP" > ${target}
        ${pkgs.coreutils}/bin/chmod 644 ${target}'';

      rootlessConfig = lib.mkIf cfg.enableRootless {
        systemd.user.services.docker.environment = {
          HTTP_PROXY = proxyUrl;
          HTTPS_PROXY = proxyUrl;
          NO_PROXY = "localhost,127.0.0.1";
          SSL_CERT_FILE = "%h/.config/docker/ca-bundle.crt";
        };

        systemd.user.services.docker-rootless-ca-setup = {
          description = "Download and setup Docker CA for rootless registry cache proxy";
          wantedBy = [ "default.target" ];
          before = [ "docker.service" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            PrivateTmp = true;
            ExecStart = pkgs.writeShellScript "docker-rootless-ca-setup" ''
              set -e

              CA_TMP="$(${pkgs.coreutils}/bin/mktemp)"
              trap 'rm -f "$CA_TMP"' EXIT

              echo "Downloading CA certificate for rootless Docker"

              ${lib.concatMapStringsSep "\n" (h: ''
                mkdir -p "$HOME/.config/docker/certs.d/${h}"'') certsdHosts}

              ${downloadCaCert}

              ${lib.concatMapStringsSep "\n" (
                h: installCa ''"$HOME/.config/docker/certs.d/${h}/ca.crt"''
              ) certsdHosts}

              ${installCaBundle ''"$HOME/.config/docker/ca-bundle.crt"''}

              mkdir -p "$HOME/.local/share/ca-certificates"
              ${installCa ''"$HOME/.local/share/ca-certificates/docker-cache-ca.crt"''}

              mkdir -p "$HOME/.docker"

              if [ -f "$HOME/.docker/config.json" ]; then
                cp "$HOME/.docker/config.json" "$HOME/.docker/config.json.bak"

                ${pkgs.jq}/bin/jq '.proxies = {
                  "default": {
                    "httpProxy": "${proxyUrl}",
                    "httpsProxy": "${proxyUrl}",
                    "noProxy": "localhost,127.0.0.1"
                  }
                }' "$HOME/.docker/config.json.bak" > "$HOME/.docker/config.json"
              else
                cat > "$HOME/.docker/config.json" <<EOF
              {
                "proxies": {
                  "default": {
                    "httpProxy": "${proxyUrl}",
                    "httpsProxy": "${proxyUrl}",
                    "noProxy": "localhost,127.0.0.1"
                  }
                }
              }
              EOF
              fi

              chmod 600 "$HOME/.docker/config.json"

              echo "CA certificate installed for rootless Docker"
            '';
          };
        };
      };
    in
    lib.mkMerge [
      {
        virtualisation.docker.daemon.settings = dockerDaemonConfig;

        systemd.services.docker.environment = {
          HTTP_PROXY = proxyUrl;
          HTTPS_PROXY = proxyUrl;
          NO_PROXY = "localhost,127.0.0.1";
          SSL_CERT_FILE = "/etc/docker/ca-bundle.crt";
        };

        systemd.tmpfiles.rules = [
          "d /etc/docker/certs.d 0755 root root -"
        ] ++ map (h: "d /etc/docker/certs.d/${h} 0755 root root -") certsdHosts;

        systemd.services.docker-ca-setup = {
          description = "Download and setup Docker CA for registry cache proxy";
          wantedBy = [ "docker.service" ];
          before = [ "docker.service" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = "10s";
            PrivateTmp = true;
            ExecStart = pkgs.writeShellScript "docker-ca-setup" ''
              set -e

              CA_TMP="$(${pkgs.coreutils}/bin/mktemp)"
              trap 'rm -f "$CA_TMP"' EXIT

              echo "Downloading CA certificate from docker cache proxy"

              ${downloadCaCert}

              ${lib.concatMapStringsSep "\n" (
                h: installCa "/etc/docker/certs.d/${h}/ca.crt"
              ) certsdHosts}

              ${installCaBundle "/etc/docker/ca-bundle.crt"}

              echo "CA certificate installed for Docker daemon"
            '';
          };
        };
      }
      rootlessConfig
    ]
  );
}
