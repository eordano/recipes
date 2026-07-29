# minimal-oci-image
#
# Build a super-minimal OCI/Docker image straight out of the Nix store: no
# distro, no package manager, no shell -- only the closure of the program you
# name, plus the handful of things that are ALWAYS missing from such an image
# and fail in confusing ways when they are (CA certificates, /etc/passwd,
# /etc/nsswitch.conf, /tmp, $PATH, zoneinfo).
#
# Usage:
#
#   oci = import ./lib/minimal-oci-image { inherit pkgs; };
#
#   myImage = oci.mkMinimalImage {
#     name       = "myapp";              # MUST be lowercase (see README)
#     tag        = "1.0.0";
#     entrypoint = [ (pkgs.lib.getExe pkgs.myapp) ];
#     user       = "app";                # non-root, with a real passwd entry
#     tls        = true;                 # ship a CA bundle + point every
#                                        # library at it
#   };
#
#   # then: docker load < result   (or `result | docker load` when streamed)
#
# See README.md for the traps this encodes.

{
  pkgs,
  lib ? pkgs.lib,
}:

let
  inherit (pkgs) dockerTools;

  mkMinimalImage =
    {
      # Image name. Lowercased by dockerTools for `imageName`, so pass it
      # lowercase or the tarball name and the loaded name disagree.
      name,

      # Image tag. `null` makes dockerTools derive the tag from the output
      # hash -- reproducible, but it changes whenever the closure changes.
      tag ? "latest",

      # Exec-form entrypoint/command. There is no shell form: these are argv
      # arrays handed straight to execve. Use absolute store paths.
      entrypoint ? [ ],
      cmd ? [ ],

      # Packages whose file trees land in the image root (and whose bin/ dirs
      # go on $PATH). For a true single-binary image leave this empty and put
      # the store path in `entrypoint` -- the closure is pulled in either way.
      contents ? [ ],

      # Environment as an attrset, merged over the computed defaults. An
      # attrset (not a list) so a caller override REPLACES the default instead
      # of appending a duplicate key -- the OCI spec does not define which
      # duplicate wins.
      env ? { },

      # "layered" -> buildLayeredImage (tarball, one store path per layer)
      # "stream"  -> streamLayeredImage (script that writes the tarball)
      # "single"  -> buildImage (one flat layer from a buildEnv)
      builder ? "layered",

      # Only meaningful for the layered builders. nixpkgs default is 100.
      maxLayers ? 100,

      # Ship a CA bundle at the three conventional locations and point the
      # usual env vars at it. Without this, every TLS client in the image
      # fails with "unable to get local issuer certificate" or similar.
      tls ? true,

      # Ship /etc/passwd, /etc/group, /etc/nsswitch.conf and /var/empty.
      nss ? true,

      # Non-root user name, or null to run as uid 0. Requires `nss`.
      user ? null,
      uid ? 65532,
      gid ? 65532,
      home ? "/var/empty",

      # Add /bin/sh (bash). Off by default -- that is the point of the recipe.
      # Turn it on when something outside your control needs a shell
      # (HEALTHCHECK CMD, `kubectl exec`, an entrypoint wrapper script).
      shell ? false,

      # Add coreutils and /usr/bin/env. Debug aids; off by default.
      coreutils ? false,
      usrBinEnv ? false,

      # IANA zone name, e.g. "Europe/Berlin". null leaves the image on UTC and
      # ships no zoneinfo at all.
      timezone ? null,

      # "single" copies exactly one TZif file to /etc/localtime and keeps
      # tzdata OUT of the closure. "full" ships the whole zoneinfo database
      # and sets TZDIR/TZ, which is what you need if the app resolves zone
      # names at runtime -- and costs ~10 MB.
      zoneinfo ? "single",

      # World-writable /tmp. Many libraries assume it exists.
      tmp ? true,

      workingDir ? null,
      exposedPorts ? { },
      volumes ? { },
      labels ? { },

      # Creation timestamp. Keep the epoch default for reproducibility;
      # "now" makes the image non-reproducible.
      created ? "1970-01-01T00:00:01Z",
      mtime ? "1970-01-01T00:00:01Z",

      architecture ? null,

      # Extra shell run in the (unpacked) image root before it is tarred.
      # Mode bits survive; ownership does not -- use `fakeRootCommands` for
      # chown, which the layered builders accept via `extraArgs`.
      extraCommands ? "",

      # Merged over the generated OCI config; wins on conflict.
      extraConfig ? { },

      extraPasswdLines ? [ ],
      extraGroupLines ? [ ],

      # Passed through to the underlying dockerTools builder untouched
      # (fromImage, fakeRootCommands, enableFakechroot, includeNixDB, ...).
      extraArgs ? { },
    }:
    let
      nologin = "/sbin/nologin";

      fakeNss = pkgs.fakeNss.override {
        extraPasswdLines =
          lib.optional (user != null)
            "${user}:x:${toString uid}:${toString gid}:${user}:${home}:${nologin}"
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

      # `lib.makeBinPath []` is the empty string; splicing that into a PATH
      # yields an empty element, which means "the current directory".
      pathParts = lib.filter (s: s != "") [
        (lib.makeBinPath (contents ++ lib.optional shell pkgs.bashInteractive
          ++ lib.optional coreutils pkgs.coreutils))
        "/bin"
        "/usr/bin"
      ];

      caBundle = "/etc/ssl/certs/ca-bundle.crt";

      defaultEnv =
        {
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
        # With zoneinfo = "single" there is no zone DATABASE to look a name up
        # in, so TZ must stay unset: glibc falls back to /etc/localtime, which
        # is exactly the file that was copied in. Setting TZ=<name> without a
        # TZDIR silently reverts the container to UTC.
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
          # Numeric, not the name: the kernel needs no nss lookup for it, so
          # the image still starts if /etc/passwd is ever dropped.
          User = if user == null then null else "${toString uid}:${toString gid}";
          WorkingDir = workingDir;
          ExposedPorts = exposedPorts;
          Volumes = volumes;
          Labels = labels;
        }
        // extraConfig;

      # `buildImage` rsyncs store trees into the layer with their store modes
      # intact (read-only), and only chmods the layer ROOT writable. So a bare
      # `mkdir -p etc/...` or `mkdir -p var/tmp` fails with EACCES the moment
      # `etc`/`var` came from a package. The layered builders use a symlinkJoin
      # (writable dirs) and do not hit this. Make the top level writable first
      # so the same commands work under every builder.
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
            # `install`, not `ln -s`: a symlink into the store would drag the
            # whole 10 MB zoneinfo database into the closure. A copied TZif
            # file contains no store references, so it does not.
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

      common =
        {
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
    assert lib.assertMsg (user == null || nss)
      "minimal-oci-image: user=${toString user} needs nss=true, otherwise nothing can resolve that uid";
    assert lib.assertMsg (lib.elem zoneinfo [ "single" "full" ])
      "minimal-oci-image: zoneinfo must be \"single\" or \"full\", got ${zoneinfo}";
    if builder == "layered" then
      dockerTools.buildLayeredImage layeredArgs
    else if builder == "stream" then
      dockerTools.streamLayeredImage layeredArgs
    else if builder == "single" then
      dockerTools.buildImage singleArgs
    else
      throw "minimal-oci-image: builder must be one of layered|stream|single, got ${builder}";

  examples = {
    # The floor: one program, its closure, nothing else. No shell, no certs,
    # no passwd, no /tmp -- runs as root because there is no one else.
    bare = mkMinimalImage {
      name = "example-bare";
      tag = "1";
      entrypoint = [ (lib.getExe pkgs.hello) ];
      tls = false;
      nss = false;
      tmp = false;
    };

    # The realistic floor: same program, plus the four things a networked
    # service actually needs. Non-root, TLS-capable, timezone-aware.
    service = mkMinimalImage {
      name = "example-service";
      tag = "1";
      entrypoint = [ (lib.getExe pkgs.hello) ];
      user = "app";
      timezone = "UTC";
    };

    # A TLS client, to demonstrate that certificates work.
    tlsClient = mkMinimalImage {
      name = "example-tls-client";
      tag = "1";
      contents = [ pkgs.curl ];
      entrypoint = [ (lib.getExe pkgs.curl) ];
      user = "app";
    };

    # Same contents as `service` flattened into ONE layer, for comparison.
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
