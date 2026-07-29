# pip-mirror-client — point every host's pip at an internal PyPI mirror.
#
# Writes a system-wide /etc/pip.conf so that *every* invocation of pip on the
# host (any user, any venv that doesn't override it) fetches packages from an
# internal mirror instead of the public PyPI. This cuts WAN traffic and keeps
# `pip install` working when the public index is slow or unreachable.
#
# SECURITY: the `trusted-host` line tells pip to SKIP TLS certificate
# verification for that host, system-wide. It is only needed when the mirror
# terminates TLS with a certificate pip does not trust by default (a private
# CA, a self-signed cert) or serves plain HTTP. If your mirror has a valid,
# publicly/corporate-trusted certificate, leave `trustedHost` unset ("") so
# full TLS verification stays on. Setting it weakens security and should be a
# deliberate choice, not a default.
#
# Usage:
#   imports = [ ./pip-mirror-client ];
#   behaviors.pip-mirror.enable    = true;
#   behaviors.pip-mirror.mirrorUrl = "https://pypi.example.com/index/";
#   # Only for a self-signed / private-CA / plain-HTTP mirror:
#   # behaviors.pip-mirror.trustedHost = "pypi.example.com";
{
  config,
  lib,
  ...
}:
let
  cfg = config.behaviors.pip-mirror;
in
{
  options.behaviors.pip-mirror = {
    enable = lib.mkEnableOption "system-wide pip mirror via /etc/pip.conf";

    mirrorUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://pypi.example.com/index/";
      description = ''
        Full index URL of the internal PyPI mirror, written as pip's
        `index-url`. Include the scheme and any path prefix the mirror expects
        (e.g. a trailing `/index/`).

        SECURITY: this value is written verbatim into the world-readable
        `/etc/pip.conf` (mode 0444) and into the Nix store. Do NOT embed
        credentials here (e.g. `https://user:token@mirror/...`) — any local
        user could read them, and they would be copied to any binary cache the
        closure is pushed to. Supply mirror credentials out-of-band instead
        (a per-user `~/.netrc` or a keyring pip can read).
      '';
    };

    trustedHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "pypi.example.com";
      description = ''
        Bare hostname (optionally `host:port`) added under pip's [install]
        `trusted-host`.

        SECURITY: setting this makes pip SKIP TLS certificate verification for
        that host, system-wide, for every user and venv. Leave it empty (the
        default) so TLS verification stays on. Set it ONLY when the mirror
        serves a certificate pip does not trust by default (a private CA, a
        self-signed cert) or serves plain HTTP. If your mirror has a valid,
        trusted certificate, do not set this.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.mirrorUrl != "";
        message = "behaviors.pip-mirror: mirrorUrl must be set";
      }
    ];

    environment.etc."pip.conf".text = ''
      [global]
      index-url=${cfg.mirrorUrl}
    ''
    + lib.optionalString (cfg.trustedHost != "") ''
      [install]
      trusted-host=${cfg.trustedHost}
    '';
  };
}
