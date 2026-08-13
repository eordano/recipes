{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nginxBearerInject;

  snippetDir = "/run/nginx-snippets";

  snippetPathFor = name: "${snippetDir}/bearer-${name}.conf";

  injectorOptions =
    { name, config, ... }:
    {
      options = {
        mode = lib.mkOption {
          type = lib.types.enum [
            "real"
            "passthrough"
          ];
          default = "real";
          description = ''
            "real" injects the bearer read from `secretFile`. "passthrough"
            injects a self-generated cosmetic token (for upstreams that require
            an Authorization header to be present but do not validate it).
          '';
        };

        secretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Path to the file holding the raw bearer, read at render time by the
            (root) oneshot service. Required in "real" mode, ignored in
            "passthrough" mode. This is a runtime path (e.g.
            `config.age.secrets.<name>.path`), NOT the secret value -- do not
            put the value here or it lands in the store.
          '';
          example = lib.literalExpression "config.age.secrets.upstream-api-key.path";
        };

        keyPrefix = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Literal prefix prepended to the key inside the header value, e.g.
            "sk-" so the header reads `Authorization: Bearer sk-<key>`. Applies
            to both modes.
          '';
          example = "sk-";
        };

        snippetMode = lib.mkOption {
          type = lib.types.str;
          default = "0640";
          description = ''
            Permission bits on the rendered `/run` snippet. nginx reads
            `include` files at config-load time as the master process (root), so
            the group only needs to cover whatever else you let read it. The
            default 0640 root:<nginx group> is deliberately tighter than
            world-readable -- the secret-owner permissions are the point.
          '';
        };

        snippetPath = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          default = snippetPathFor name;
          description = ''
            Read-only computed path of the rendered `include` file. Reference it
            from your vhost, e.g.
            `extraConfig = "include ''${config.services.nginxBearerInject.injectors.foo.snippetPath};";`
          '';
        };
      };
    };

  renderOne =
    name: inj:
    let
      path = snippetPathFor name;
      acquireKey =
        if inj.mode == "real" then
          ''
            if [ ! -s ${lib.escapeShellArg inj.secretFile} ]; then
              echo "nginx-bearer-inject (${name}): secret file ${inj.secretFile} missing or empty" >&2
              exit 1
            fi
            KEY=$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg inj.secretFile})
          ''
        else
          ''
            KEY=$(${pkgs.coreutils}/bin/head -c 24 /dev/urandom \
              | ${pkgs.coreutils}/bin/base64 \
              | ${pkgs.gnused}/bin/sed 's/[^a-zA-Z0-9]//g' \
              | ${pkgs.coreutils}/bin/head -c 32)
          '';
    in
    ''
      ${acquireKey}
      umask 027
      ${pkgs.coreutils}/bin/printf 'proxy_set_header Authorization "Bearer %s";\n' \
        "${inj.keyPrefix}$KEY" > ${path}.tmp
      ${pkgs.coreutils}/bin/mv -f ${path}.tmp ${path}
      ${pkgs.coreutils}/bin/chmod ${inj.snippetMode} ${path}
      ${pkgs.coreutils}/bin/chgrp ${cfg.nginxGroup} ${path} || true
    '';

  renderScript = lib.concatStringsSep "\n" (lib.mapAttrsToList renderOne cfg.injectors);

  realInjectorsMissingSecret = lib.filterAttrs (
    _: inj: inj.mode == "real" && inj.secretFile == null
  ) cfg.injectors;
in
{
  options.services.nginxBearerInject = {
    injectors = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule injectorOptions);
      default = { };
      description = ''
        Named bearer injectors. Each renders one `include` file under /run that
        you reference from a vhost location's `extraConfig`.
      '';
    };

    nginxGroup = lib.mkOption {
      type = lib.types.str;
      default = config.services.nginx.group or "nginx";
      description = "Group that owns the rendered snippets (typically nginx's).";
    };
  };

  config = lib.mkIf (cfg.injectors != { }) {
    assertions = [
      {
        assertion = realInjectorsMissingSecret == { };
        message =
          "services.nginxBearerInject: injector(s) "
          + lib.concatStringsSep ", " (lib.attrNames realInjectorsMissingSecret)
          + " are in \"real\" mode but have no secretFile.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${snippetDir} 0755 root root -"
    ];

    systemd.services.nginx-bearer-inject = {
      description = "Render nginx bearer-injection include files from secrets into /run";
      before = [ "nginx.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        install -d -m 0755 ${snippetDir}
        ${renderScript}
      '';
    };

    systemd.services.nginx = {
      after = [ "nginx-bearer-inject.service" ];
      wants = [ "nginx-bearer-inject.service" ];
    };
  };
}
