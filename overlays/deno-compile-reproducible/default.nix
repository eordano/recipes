{
  lib,
  stdenv,
  fetchurl,
  deno,
  cacert,
}:

{
  pname,
  version,
  src,
  depsHash,
  denortHash,

  entrypoint ? "src/main.ts",
  cacheFiles ? [ entrypoint ],
  includes ? [ ],
  installBinaryName ? pname,
  compiledOutputName ? "compiled_binary",

  compileFlags ? [
    "--allow-net"
    "--allow-env"
    "--allow-read"
  ],

  denortTarget ? "x86_64-unknown-linux-gnu",

  patches ? [ ],
  extraNativeBuildInputs ? [ ],
  extraInstall ? "",
  meta ? { },
}:

let
  denortZip = fetchurl {
    url = "https://dl.deno.land/release/v${deno.version}/denort-${denortTarget}.zip";
    hash = denortHash;
  };

  deps = stdenv.mkDerivation {
    pname = "${pname}-deps";
    inherit version src;

    nativeBuildInputs = [
      deno
      cacert
    ];

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

  dontStrip = true;
  dontPatchELF = true;

  passthru = { inherit deps denortZip; };
}
