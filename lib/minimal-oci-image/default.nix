{
  pkgs,
  lib ? pkgs.lib,
}:

let
  inherit (pkgs) dockerTools;

  mkMinimalImage =
    {
      name,

      tag ? "latest",

      entrypoint ? [ ],
      cmd ? [ ],

      contents ? [ ],

      env ? { },

      builder ? "layered",

      maxLayers ? 100,

      tls ? true,

      nss ? true,

      user ? null,
      uid ? 65532,
      gid ? 65532,
      home ? "/var/empty",

      shell ? false,

      coreutils ? false,
      usrBinEnv ? false,

      timezone ? null,

      zoneinfo ? "single",

      tmp ? true,

      workingDir ? null,
      exposedPorts ? { },
      volumes ? { },
      labels ? { },

      created ? "1970-01-01T00:00:01Z",
      mtime ? "1970-01-01T00:00:01Z",

      architecture ? null,

      extraCommands ? "",

      extraConfig ? { },

      extraPasswdLines ? [ ],
      extraGroupLines ? [ ],

      extraArgs ? { },
    }:
    let
      nologin = "/sbin/nologin";

      fakeNss = pkgs.fakeNss.override {
        extraPasswdLines =
          lib.optional (user != null) "${user}:x:${toString uid}:${toString gid}:${user}:${home}:${nologin}"
          ++ extraPasswdLines;
        extraGroupLines = lib.optional (user != null) "${user}:x:${toString gid}:" ++ extraGroupLines;
      };

      extras =
        lib.optional tls dockerTools.caCertificates
        ++ lib.optional nss fakeNss
        ++ lib.optional shell dockerTools.binSh
        ++ lib.optional usrBinEnv dockerTools.usrBinEnv
        ++ lib.optional shell pkgs.bashInteractive
        ++ lib.optional coreutils pkgs.coreutils
        ++ lib.optional (timezone != null && zoneinfo == "full") pkgs.tzdata;

      allContents = contents ++ extras;

      pathParts = lib.filter (s: s != "") [
        (lib.makeBinPath (
          contents ++ lib.optional shell pkgs.bashInteractive ++ lib.optional coreutils pkgs.coreutils
        ))
        "/bin"
        "/usr/bin"
      ];

      caBundle = "/etc/ssl/certs/ca-bundle.crt";

      defaultEnv = {
        PATH = lib.concatStringsSep ":" pathParts;
        HOME = home;
      }
      // lib.optionalAttrs tls {
        SSL_CERT_FILE = caBundle;
        NIX_SSL_CERT_FILE = caBundle;
        CURL_CA_BUNDLE = caBundle;
        GIT_SSL_CAINFO = caBundle;
        REQUESTS_CA_BUNDLE = caBundle;
      }
      // lib.optionalAttrs (timezone != null && zoneinfo == "full") {
        TZDIR = "${pkgs.tzdata}/share/zoneinfo";
        TZ = timezone;
      };

      finalEnv = defaultEnv // env;

      imageConfig =
        lib.filterAttrs (_: v: v != null && v != [ ] && v != { }) {
          Entrypoint = entrypoint;
          Cmd = cmd;
          Env = lib.mapAttrsToList (k: v: "${k}=${toString v}") finalEnv;
          User = if user == null then null else "${toString uid}:${toString gid}";
          WorkingDir = workingDir;
          ExposedPorts = exposedPorts;
          Volumes = volumes;
          Labels = labels;
        }
        // extraConfig;

      writableTop = ''
        for d in etc var usr; do
          if [ -d "$d" ]; then chmod u+w "$d"; fi
        done
      '';

      steps =
        lib.optional tmp ''
          mkdir -p tmp var/tmp
          chmod 1777 tmp var/tmp
        ''
        ++ lib.optional (timezone != null) (
          if zoneinfo == "full" then
            ''
              mkdir -p etc
              ln -sf ${pkgs.tzdata}/share/zoneinfo/${timezone} etc/localtime
              echo ${timezone} > etc/timezone
            ''
          else
            ''
              mkdir -p etc
              install -m 0644 ${pkgs.tzdata}/share/zoneinfo/${timezone} etc/localtime
              echo ${timezone} > etc/timezone
            ''
        )
        ++ lib.optional (extraCommands != "") extraCommands;

      rootCommands = lib.optionalString (steps != [ ]) (
        lib.concatStringsSep "\n" ([ writableTop ] ++ steps)
      );

      common = {
        inherit name created;
        config = imageConfig;
      }
      // lib.optionalAttrs (tag != null) { inherit tag; }
      // lib.optionalAttrs (architecture != null) { inherit architecture; };

      layeredArgs =
        common
        // {
          contents = allContents;
          inherit maxLayers mtime;
          extraCommands = rootCommands;
        }
        // extraArgs;

      singleArgs =
        common
        // {
          copyToRoot = pkgs.buildEnv {
            name = "${name}-root";
            paths = allContents;
            pathsToLink = [
              "/bin"
              "/etc"
              "/share"
              "/lib"
              "/var"
            ];
            ignoreCollisions = true;
          };
          extraCommands = rootCommands;
        }
        // extraArgs;
    in
    assert lib.assertMsg (name == lib.toLower name)
      "minimal-oci-image: image name ${name} must be lowercase; dockerTools lowercases imageName and the two would disagree";
    assert lib.assertMsg (user != null || (uid == 65532 && gid == 65532))
      "minimal-oci-image: uid/gid are only meaningful together with `user`; without it the image runs as root and nothing reads them";
    assert lib.assertMsg (
      user == null || nss
    ) "minimal-oci-image: user=${toString user} needs nss=true, otherwise nothing can resolve that uid";
    assert lib.assertMsg (lib.elem zoneinfo [
      "single"
      "full"
    ]) "minimal-oci-image: zoneinfo must be \"single\" or \"full\", got ${zoneinfo}";
    if builder == "layered" then
      dockerTools.buildLayeredImage layeredArgs
    else if builder == "stream" then
      dockerTools.streamLayeredImage layeredArgs
    else if builder == "single" then
      dockerTools.buildImage singleArgs
    else
      throw "minimal-oci-image: builder must be one of layered|stream|single, got ${builder}";

  examples = {
    bare = mkMinimalImage {
      name = "example-bare";
      tag = "1";
      entrypoint = [ (lib.getExe pkgs.hello) ];
      tls = false;
      nss = false;
      tmp = false;
    };

    service = mkMinimalImage {
      name = "example-service";
      tag = "1";
      entrypoint = [ (lib.getExe pkgs.hello) ];
      user = "app";
      timezone = "UTC";
    };

    tlsClient = mkMinimalImage {
      name = "example-tls-client";
      tag = "1";
      contents = [ pkgs.curl ];
      entrypoint = [ (lib.getExe pkgs.curl) ];
      user = "app";
    };

    singleLayer = mkMinimalImage {
      name = "example-single-layer";
      tag = "1";
      builder = "single";
      entrypoint = [ (lib.getExe pkgs.hello) ];
      user = "app";
      timezone = "UTC";
    };
  };
in
{
  inherit mkMinimalImage examples;
}
