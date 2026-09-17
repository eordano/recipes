_final: prev:
let
  patchedSrc = prev.applyPatches {
    name = "redlib-source-patched";
    src = prev.redlib.src;
    patches = [ ./redlib-socks-connector.patch ];
  };
in
{
  redlib =
    (prev.redlib.overrideAttrs (_old: {
      src = patchedSrc;
    })).overrideAttrs
      (old: {
        cargoDeps = prev.rustPlatform.fetchCargoVendor {
          name = "${old.pname or "redlib"}-${old.version}-vendor";
          src = patchedSrc;
          hash = "sha256-DQ8A5p+e2ZH1W6fjVHGs22we/nCZdhsO60cFMzvUCdM=";
        };
      });
}
