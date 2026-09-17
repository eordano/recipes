{
  packages ? [ ],
}:

_final: prev:

let
  inherit (prev) lib;

  darwinRustflags = "-C link-arg=-undefined -C link-arg=dynamic_lookup";

  patchPackage =
    _pyFinal: pyPrev: name:
    lib.optionalAttrs (pyPrev ? ${name}) {
      ${name} = pyPrev.${name}.overridePythonAttrs (old: {
        env =
          (old.env or { })
          // lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
            RUSTFLAGS = darwinRustflags;
          };
      });
    };
in
{
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: lib.foldl' (acc: name: acc // patchPackage pyFinal pyPrev name) { } packages)
  ];
}
