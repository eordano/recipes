# deno-prebuilt-darwin-overlay
#
# A nixpkgs overlay that replaces the source-built `deno` with the official
# prebuilt release binary from GitHub -- but only on macOS, where deno's
# `rusty-v8` source build reliably fails.
#
# Usage -- add to your nixpkgs overlays:
#
#     nixpkgs.overlays = [ (import ./deno-prebuilt-darwin-overlay) ];
#
# or, with flakes:
#
#     pkgs = import nixpkgs {
#       inherit system;
#       overlays = [ (import ./overlays/deno-prebuilt-darwin-overlay) ];
#     };
#
# To bump the version: change `version` below and update both `hashes`
# entries. Get the hashes with, for each arch:
#
#     nix store prefetch-file --json \
#       https://github.com/denoland/deno/releases/download/v<VERSION>/deno-<ARCH>.zip
#
# where <ARCH> is aarch64-apple-darwin or x86_64-apple-darwin. Or leave a
# hash as lib.fakeHash and let the build tell you the correct value.

_: prev:
let
  inherit (prev) lib stdenv fetchurl;

  # Pin the deno release. Bump both `version` and the matching `hashes`
  # entries together -- a stale hash fails the fetch, a stale version pulls
  # an old binary.
  version = "2.7.14";

  # Prebuilt release archives are published per Apple arch. Both darwin
  # arches are covered so the overlay resolves on Intel and Apple Silicon
  # Macs alike.
  hashes = {
    aarch64-apple-darwin = "sha256-rrWCX4O0qc1/k1WhxN3WZiBdrPdsy3uYwrEOBmvJ5Ls=";
    # Placeholder -- replace with the real x86_64 release hash before using on
    # an Intel Mac (see prefetch command above). lib.fakeHash makes the build
    # fail loudly with the correct hash rather than silently mis-resolving.
    x86_64-apple-darwin = lib.fakeHash;
  };

  arch =
    if stdenv.hostPlatform.system == "aarch64-darwin" then
      "aarch64-apple-darwin"
    else if stdenv.hostPlatform.system == "x86_64-darwin" then
      "x86_64-apple-darwin"
    else
      throw "deno-prebuilt-darwin-overlay: unsupported system ${stdenv.hostPlatform.system}";

  src = fetchurl {
    url = "https://github.com/denoland/deno/releases/download/v${version}/deno-${arch}.zip";
    hash = hashes.${arch};
  };
in
# Guard with optionalAttrs on isDarwin: on Linux (and anywhere else) this
# overlay contributes nothing, so the normal source build is used there.
lib.optionalAttrs stdenv.hostPlatform.isDarwin {
  deno = prev.stdenv.mkDerivation {
    pname = "deno-bin";
    inherit version src;

    nativeBuildInputs = [ prev.unzip ];

    # The release zip contains a single `deno` executable at its root, so the
    # unpacked source root is just the current directory.
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall
      install -Dm755 deno $out/bin/deno
      runHook postInstall
    '';

    meta = {
      description = "Prebuilt Deno binary (workaround for failing rusty-v8 source build on darwin)";
      homepage = "https://deno.com";
      license = lib.licenses.mit;
      mainProgram = "deno";
      platforms = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    };
  };
}
