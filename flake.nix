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
      };

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          geoip-countrylist = pkgs.callPackage ./packages/geoip-countrylist.nix { };
          default = self.packages.${system}.geoip-countrylist;
        }
      );

      nixosModules = {
        firewall-by-country = import ./modules/firewall-by-country.nix;
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
        }
      );
    };
}
