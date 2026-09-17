{
  packages ? [ "element-web" ],
}:

_final: prev:

prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-linux") (
  let
    pkgsX86 = import prev.path {
      system = "x86_64-linux";
      inherit (prev) config;
    };
  in
  prev.lib.genAttrs packages (name: pkgsX86.${name})
)
