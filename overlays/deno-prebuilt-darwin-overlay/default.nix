_: prev:
let
  inherit (prev) lib stdenv fetchurl;

  version = "2.7.14";

  hashes = {
    aarch64-apple-darwin = "sha256-rrWCX4O0qc1/k1WhxN3WZiBdrPdsy3uYwrEOBmvJ5Ls=";
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
lib.optionalAttrs stdenv.hostPlatform.isDarwin {
  deno = prev.stdenv.mkDerivation {
    pname = "deno-bin";
    inherit version src;

    nativeBuildInputs = [ prev.unzip ];

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
