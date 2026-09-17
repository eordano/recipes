{
  pkgs ? import <nixpkgs> { },

  mlx-lm ? pkgs.python3Packages.mlx-lm,

  extraPythonPackages ? [ pkgs.python3Packages.sentencepiece ],
}:

let
  python = pkgs.python3.withPackages (_: [ mlx-lm ] ++ extraPythonPackages);
in

pkgs.writeShellScriptBin "mlx-lm-server" ''
  exec ${python}/bin/python -m mlx_lm server "$@"
''
