{
  description = "NixOS modules and tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      overlays.default = final: prev: {
        geoip-countrylist = final.callPackage ./packages/geoip-countrylist.nix { };
        verdaccio = final.callPackage ./packages/verdaccio.nix { };
      };

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          geoip-countrylist = pkgs.callPackage ./packages/geoip-countrylist.nix { };
          verdaccio = pkgs.callPackage ./packages/verdaccio.nix { };
          default = self.packages.${system}.geoip-countrylist;
        }
      );

      nixosModules = {
        # Server-side service modules
        firewall-by-country = import ./modules/firewall-by-country.nix;
        docker-cache = import ./modules/docker-cache.nix;
        pypi-cache = import ./modules/pypi-cache.nix;
        nix-cache = import ./modules/nix-cache.nix;
        huggingface-cache = import ./modules/huggingface-cache.nix;
        npm-cache = import ./modules/npm-cache.nix;

        # Client-side behavior modules
        use-docker-cache = import ./behaviors/use-docker-cache.nix;
        use-pypi-cache = import ./behaviors/use-pypi-cache.nix;
        use-nix-cache = import ./behaviors/use-nix-cache.nix;
        use-huggingface-cache = import ./behaviors/use-huggingface-cache.nix;
        use-npm-cache = import ./behaviors/use-npm-cache.nix;

        default = self.nixosModules.firewall-by-country;
      };

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
        in
        {
          firewall-by-country = import ./tests/firewall-by-country.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };

          pypi-cache = import ./tests/pypi-cache.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };

          nix-cache = import ./tests/nix-cache.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };

          huggingface-cache = import ./tests/huggingface-cache.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };

          npm-cache = import ./tests/npm-cache.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };

          docker-cache = import ./tests/docker-cache.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };
        }
      );
    };
}
