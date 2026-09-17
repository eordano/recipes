{
  pkgs ? import <nixpkgs> { },

  mlx-lm ? pkgs.python3Packages.mlx-lm,
}:

mlx-lm
