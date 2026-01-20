{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.behaviors.docker-cache;
in {
  options.behaviors.docker-cache = {
    enable = lib.mkEnableOption "Use docker registry cache proxy";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://docker-cache.home.lan";
      description = "URL of the docker registry cache";
    };

    proxyPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "Port for the HTTP proxy (defaults to 3128)";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # Parse the cache URL to extract components
      urlParts = builtins.match "^(https?)://([^:/]+)(:([0-9]+))?(/.*)?$" cfg.cacheUrl;

      # Extract components with defaults
      cacheProtocol =
        if urlParts != null
        then builtins.elemAt urlParts 0
        else "http";
      cacheDomain =
        if urlParts != null
        then builtins.elemAt urlParts 1
        else "docker-cache.home.lan";
      cachePort =
        if urlParts != null && builtins.elemAt urlParts 3 != null
        then lib.toInt (builtins.elemAt urlParts 3)
        else if cacheProtocol == "https"
        then 443
        else 80;

      # Determine proxy port
      proxyPort =
        if cfg.proxyPort != null
        then cfg.proxyPort
        else 3128;

      # Build URLs
      proxyUrl = "http://${cacheDomain}:${toString proxyPort}";
      caCertUrl = "${cacheProtocol}://${cacheDomain}${
        if cachePort == 443 || cachePort == 80
        then ""
        else ":${toString cachePort}"
      }/ca.crt";

      # Docker daemon configuration
      dockerDaemonConfig = {
        proxies = {
          "http-proxy" = proxyUrl;
          "https-proxy" = proxyUrl;
          "no-proxy" = "localhost,127.0.0.1";
        };
      };
    in {
      # Configure Docker daemon to use proxy via daemon.json
      virtualisation.docker.daemon.settings = dockerDaemonConfig;

      # Also set environment variables as fallback
      systemd.services.docker.environment = {
        HTTP_PROXY = proxyUrl;
        HTTPS_PROXY = proxyUrl;
        NO_PROXY = "localhost,127.0.0.1";
        SSL_CERT_FILE = "/etc/docker/ca-bundle.crt";
      };

      # Create Docker certs directories
      systemd.tmpfiles.rules = [
        "d /etc/docker/certs.d 0755 root root -"
        "d /etc/docker/certs.d/${cacheDomain}:${toString proxyPort} 0755 root root -"
        "d /etc/docker/certs.d/registry-1.docker.io 0755 root root -"
        "d /etc/docker/certs.d/registry.docker.io 0755 root root -"
      ];

      # Download and install CA certificate from the docker-cache server
      systemd.services.docker-ca-setup = {
        description = "Download and setup Docker CA for registry cache proxy";
        wantedBy = ["docker.service"];
        before = ["docker.service"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "10s";
          ExecStart = pkgs.writeScript "docker-ca-setup" ''
            #!${pkgs.bash}/bin/bash
            set -e

            echo "Downloading CA certificate from docker-cache proxy"

            # Download CA certificate from the server with retries
            max_attempts=30
            attempt=0
            while [ $attempt -lt $max_attempts ]; do
              if ${pkgs.curl}/bin/curl -f -s -o /tmp/docker-cache-ca.crt "${caCertUrl}"; then
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
            done

            # Install CA certificate for Docker daemon to trust the proxy
            ${pkgs.coreutils}/bin/install -m 644 /tmp/docker-cache-ca.crt \
              /etc/docker/certs.d/${cacheDomain}:${toString proxyPort}/ca.crt

            # Also install for Docker Hub registries
            ${pkgs.coreutils}/bin/install -m 644 /tmp/docker-cache-ca.crt \
              /etc/docker/certs.d/registry-1.docker.io/ca.crt
            ${pkgs.coreutils}/bin/install -m 644 /tmp/docker-cache-ca.crt \
              /etc/docker/certs.d/registry.docker.io/ca.crt

            # Create CA bundle for Docker (system CA + proxy CA)
            ${pkgs.coreutils}/bin/cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
              /tmp/docker-cache-ca.crt > /etc/docker/ca-bundle.crt
            ${pkgs.coreutils}/bin/chmod 644 /etc/docker/ca-bundle.crt

            # Cleanup temp file
            rm -f /tmp/docker-cache-ca.crt

            echo "CA certificate installed for Docker daemon"
          '';
        };
      };

      # Configure rootless Docker environment
      systemd.user.services.docker.environment = {
        HTTP_PROXY = proxyUrl;
        HTTPS_PROXY = proxyUrl;
        NO_PROXY = "localhost,127.0.0.1";
        SSL_CERT_FILE = "%h/.config/docker/ca-bundle.crt";
      };

      # For rootless Docker, also install CA in user's Docker config
      systemd.user.services.docker-rootless-ca-setup = {
        description = "Download and setup Docker CA for rootless registry cache proxy";
        wantedBy = ["default.target"];
        before = ["docker.service"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeScript "docker-rootless-ca-setup" ''
            #!${pkgs.bash}/bin/bash
            set -e

            echo "Downloading CA certificate for rootless Docker"

            # Create directories
            mkdir -p "$HOME/.config/docker/certs.d/${cacheDomain}:${toString proxyPort}"
            mkdir -p "$HOME/.config/docker/certs.d/registry-1.docker.io"
            mkdir -p "$HOME/.config/docker/certs.d/registry.docker.io"

            # Download CA certificate from the server with retries
            max_attempts=30
            attempt=0
            while [ $attempt -lt $max_attempts ]; do
              if ${pkgs.curl}/bin/curl -f -s -o /tmp/docker-cache-ca.crt "${caCertUrl}"; then
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
            done

            # Install CA certificate for rootless Docker
            ${pkgs.coreutils}/bin/install -m 644 /tmp/docker-cache-ca.crt \
              "$HOME/.config/docker/certs.d/${cacheDomain}:${toString proxyPort}/ca.crt"
            ${pkgs.coreutils}/bin/install -m 644 /tmp/docker-cache-ca.crt \
              "$HOME/.config/docker/certs.d/registry-1.docker.io/ca.crt"
            ${pkgs.coreutils}/bin/install -m 644 /tmp/docker-cache-ca.crt \
              "$HOME/.config/docker/certs.d/registry.docker.io/ca.crt"

            # Create CA bundle for rootless Docker
            ${pkgs.coreutils}/bin/cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
              /tmp/docker-cache-ca.crt > "$HOME/.config/docker/ca-bundle.crt"
            ${pkgs.coreutils}/bin/chmod 644 "$HOME/.config/docker/ca-bundle.crt"

            # Create Docker CLI config with proxy settings
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
            rm -f /tmp/docker-cache-ca.crt

            echo "CA certificate installed for rootless Docker"
          '';
        };
      };
    }
  );
}
