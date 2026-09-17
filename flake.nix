{
  description = "Reusable, self-contained recipes for NixOS and nix-darwin systems";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      dirsWith =
        base:
        builtins.attrNames (
          lib.filterAttrs (_: t: t == "directory") (builtins.readDir (self + "/${base}"))
        );
      modOf = base: name: import (self + "/${base}/${name}/default.nix");
      namedFrom =
        base:
        builtins.listToAttrs (
          map (n: {
            name = n;
            value = modOf base n;
          }) (dirsWith base)
        );

      pkgDirs = dirsWith "packages";
      callablePkgDirs =
        pkgs:
        lib.filter (
          n:
          lib.all (arg: pkgs ? ${arg}) (
            lib.attrNames (
              lib.filterAttrs (_: hasDefault: !hasDefault) (
                lib.functionArgs (import (self + "/packages/${n}/default.nix"))
              )
            )
          )
        ) pkgDirs;
      packagesOverlay =
        final: _prev:
        builtins.listToAttrs (
          map (n: {
            name = n;
            value = final.callPackage (self + "/packages/${n}/default.nix") { };
          }) pkgDirs
        );

      overlaysByName = namedFrom "overlays";

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      linuxSystems = lib.filter (lib.hasSuffix "-linux") systems;
      forAllSystems = f: lib.genAttrs systems f;

      testFilesIn =
        base: name:
        let
          dir = self + "/${base}/${name}";
          files = lib.filter (f: lib.hasPrefix "test" f && lib.hasSuffix ".nix" f) (
            builtins.attrNames (builtins.readDir dir)
          );
          checkName =
            f:
            if f == "test.nix" then name else "${name}-${lib.removeSuffix ".nix" (lib.removePrefix "test-" f)}";
        in
        map (f: {
          name = checkName f;
          value = {
            recipe = name;
            file = dir + "/${f}";
          };
        }) files;

      allTests = builtins.listToAttrs (
        lib.concatMap (base: lib.concatMap (testFilesIn base) (dirsWith base)) [
          "modules"
          "behaviors"
        ]
      );
    in
    {
      nixosModules = namedFrom "modules" // namedFrom "behaviors";

      overlays = overlaysByName // {
        packages = packagesOverlay;
        default = lib.composeManyExtensions (builtins.attrValues overlaysByName ++ [ packagesOverlay ]);
      };

      lib = namedFrom "lib";

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        builtins.listToAttrs (
          map (n: {
            name = n;
            value = pkgs.callPackage (self + "/packages/${n}/default.nix") { };
          }) (callablePkgDirs pkgs)
        )
      );

      checks = lib.genAttrs linuxSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        lib.mapAttrs (_: t: import t.file { inherit pkgs; }) allTests
        // {
          same-file-as-module =
            let
              offenders = lib.filter (n: !(lib.hasInfix "./default.nix" (builtins.readFile allTests.${n}.file))) (
                lib.attrNames allTests
              );
            in
            pkgs.runCommand "same-file-as-module"
              {
                inherit offenders;
              }
              ''
                if [ -n "$offenders" ]; then
                  echo "these tests no longer import their sibling ./default.nix:" >&2
                  echo "  $offenders" >&2
                  echo "a test that builds its own copy of the module proves nothing" >&2
                  echo "about the module that nixosModules.<recipe> hands to users." >&2
                  exit 1
                fi
                touch $out
              '';
        }
      );
    };
}
