{
  description = "Reusable, self-contained recipes for NixOS and nix-darwin systems";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      # Each recipe dir with a default.nix becomes a named output.
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
      # An overlay that makes every packages/<name> available as pkgs.<name>
      # (callPackage-style derivations). Recipe dir name = package attr name.
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
        "x86_64-darwin"
      ];
      linuxSystems = lib.filter (lib.hasSuffix "-linux") systems;
      forAllSystems = f: lib.genAttrs systems (system: f system);

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
      # NixOS modules + behaviors, importable as nixosModules.<name>
      nixosModules = namedFrom "modules" // namedFrom "behaviors";

      # Package-set overlays, composable as overlays.<name>. `overlays.default`
      # composes every recipe overlay + the recipe packages; `overlays.packages`
      # adds just the packages.
      overlays = overlaysByName // {
        packages = packagesOverlay;
        default = lib.composeManyExtensions (builtins.attrValues overlaysByName ++ [ packagesOverlay ]);
      };

      # Small reusable Nix functions/values, as lib.<name> (import lazily).
      lib = namedFrom "lib";

      # Buildable derivations, per system: packages.<system>.<name>.
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        builtins.listToAttrs (
          map (n: {
            name = n;
            value = pkgs.callPackage (self + "/packages/${n}/default.nix") { };
          }) pkgDirs
        )
      );

      # checks.<system>.<recipe> runs that recipe's own test*.nix. A test sits
      # beside the default.nix it covers and imports it as `./default.nix`, so
      # the module under test is byte-for-byte the one nixosModules.<recipe>
      # exports -- there is no second copy to drift. `same-file-as-module`
      # below is what keeps that true.
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
