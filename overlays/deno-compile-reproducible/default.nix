# deno-compile-reproducible
#
# A reusable template for packaging a `deno compile` standalone binary in Nix,
# reproducibly and offline. The pattern is a TWO-PHASE build:
#
#   1. `deps`  — a FIXED-OUTPUT derivation that is allowed network access. It
#                runs `deno install` / `deno cache` to vendor every remote import
#                into $DENO_DIR, and its whole output is content-hashed
#                (outputHash). This is the ONLY derivation that touches the
#                network; bumping the source rev means recomputing outputHash.
#
#   2. main    — a normal (sandboxed, offline) derivation that copies the
#                vendored $DENO_DIR back in and runs `deno compile --cached-only`.
#                The compile step ALSO needs the matching `denort` release zip
#                dropped into the exact path deno looks for it, otherwise it
#                tries to download it at build time and fails in the sandbox.
#
# Key traps baked in below:
#   - denort zip path: deno expects it at $DENO_DIR/dl/release/v<ver>/<target>.zip
#   - dontStrip + dontPatchELF: the compiled binary embeds a payload after the
#     ELF; strip/patchelf corrupt it. Leave it untouched.
#   - the deps output must be made writable after copy (`chmod -R u+w`) because
#     store paths are read-only and deno wants to write into DENO_DIR.
#
# Import via callPackage and pass your project's parameters, e.g.
#   myTool = pkgs.callPackage ./deno-compile-reproducible {
#     pname       = "my-tool";
#     version     = "1.0.0";
#     src         = pkgs.fetchFromGitHub { ... };
#     entrypoint  = "src/main.ts";
#     cacheFiles  = [ "src/main.ts" "src/worker.ts" ];
#     includes    = [ "src/worker.ts" ];
#     depsHash    = "sha256-...";          # recompute when src changes
#     denortHash  = "sha256-...";          # matches the deno version in nixpkgs
#     compileFlags = [ "--allow-net" "--allow-env" "--allow-read" ];
#   };

{
  lib,
  stdenv,
  fetchurl,
  deno,
  cacert,
}:

{
  # --- required ---------------------------------------------------------------
  pname,
  version,
  src, # a fixed-output source (fetchFromGitHub / fetchgit / ...)
  depsHash, # hash of the vendored $DENO_DIR (phase 1 output)
  denortHash, # hash of the denort release zip for this deno version

  # --- program shape ----------------------------------------------------------
  entrypoint ? "src/main.ts", # the module `deno compile` starts from
  cacheFiles ? [ entrypoint ], # everything `deno cache` must vendor (phase 1)
  includes ? [ ], # extra modules to `--include` in the binary
  installBinaryName ? pname, # name under $out/bin
  compiledOutputName ? "compiled_binary", # temp name inside buildPhase

  # --- deno permissions / import allowlist (compile-time flags) ---------------
  # Pass exactly the --allow-* flags your program needs. Kept generic here;
  # scope them as tightly as you can in real use.
  #
  # TRAP: if your program has REMOTE imports (https:/jsr:/npm:), Deno 2 requires
  # an explicit `--allow-import=<host>:443,...` at compile time — even though
  # everything is already cached, `deno compile` still fails without it. Add the
  # hosts your import graph pulls from, e.g.
  #   "--allow-import=jsr.io:443,deno.land:443,esm.sh:443"
  compileFlags ? [
    "--allow-net"
    "--allow-env"
    "--allow-read"
  ],

  # --- denort target ----------------------------------------------------------
  # The denort runtime zip deno downloads on first compile. Must match the deno
  # binary's version AND the build platform target triple.
  denortTarget ? "x86_64-unknown-linux-gnu",

  # --- optional passthroughs --------------------------------------------------
  patches ? [ ],
  extraNativeBuildInputs ? [ ],
  extraInstall ? "", # extra shell appended to installPhase
  meta ? { },
}:

let
  # denort release zip: fetched over the network (fixed-output), then planted
  # into the path `deno compile` expects so --cached-only never reaches out.
  denortZip = fetchurl {
    url = "https://dl.deno.land/release/v${deno.version}/denort-${denortTarget}.zip";
    hash = denortHash;
  };

  # PHASE 1: vendor all remote imports into $DENO_DIR under network access.
  deps = stdenv.mkDerivation {
    pname = "${pname}-deps";
    inherit version src;

    nativeBuildInputs = [
      deno
      cacert
    ];

    # deno needs a CA bundle to fetch over HTTPS inside the FOD builder.
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    buildPhase = ''
      runHook preBuild
      export HOME=$(mktemp -d)
      export DENO_DIR="$out"
      mkdir -p "$DENO_DIR"
      # --frozen=false: tolerate a lockfile that doesn't perfectly match; drop
      # if you commit and trust deno.lock.
      deno install --frozen=false
      deno cache --frozen=false --no-check \
        ${lib.escapeShellArgs cacheFiles}
      runHook postBuild
    '';

    dontInstall = true;
    dontFixup = true;

    # Fixed-output: the vendored DENO_DIR is content-addressed. Recompute
    # depsHash whenever `src` (and therefore the import graph) changes.
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = depsHash;
  };
in
stdenv.mkDerivation {
  inherit
    pname
    version
    src
    patches
    meta
    ;

  nativeBuildInputs = [ deno ] ++ extraNativeBuildInputs;

  # PHASE 2: offline compile. No network — everything comes from `deps` + denort.
  buildPhase = ''
    runHook preBuild
    export HOME=$(mktemp -d)
    export DENO_DIR=$(mktemp -d)

    # Copy the vendored cache back in and make it writable (store is read-only,
    # deno wants to write into DENO_DIR during compile).
    cp -R ${deps}/. "$DENO_DIR"/
    chmod -R u+w "$DENO_DIR"

    # TRAP: plant the denort zip exactly where `deno compile` looks for it,
    # otherwise --cached-only still tries to download it and fails offline.
    install -Dm644 ${denortZip} \
      "$DENO_DIR/dl/release/v${deno.version}/denort-${denortTarget}.zip"

    deno compile \
      --cached-only \
      ${lib.concatMapStringsSep " " (m: "--include ${lib.escapeShellArg m}") includes} \
      --output ${lib.escapeShellArg compiledOutputName} \
      ${lib.escapeShellArgs compileFlags} \
      ${lib.escapeShellArg entrypoint}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ${lib.escapeShellArg compiledOutputName} \
      "$out/bin/${installBinaryName}"
    ${extraInstall}
    runHook postInstall
  '';

  # TRAP: a deno-compiled binary is a self-contained executable with a payload
  # appended after the ELF. Stripping or running patchelf on it corrupts the
  # embedded runtime — both MUST be disabled.
  dontStrip = true;
  dontPatchELF = true;

  passthru = { inherit deps denortZip; };
}
