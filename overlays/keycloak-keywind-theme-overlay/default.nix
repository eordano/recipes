# keycloak-keywind-theme-overlay
#
# Package the third-party Tailwind Keycloak theme "Keywind" from source with
# buildNpmPackage, and expose it in an overlay so it can be consumed by
# services.keycloak.themes.
#
# Two things live in this file:
#
#   1. keywindPackage — the package function (callPackage-style). Build the
#      theme jar from source, unzip it, and keep ONLY the login theme subdir.
#      See the comment on installPhase for the trap.
#
#   2. overlay — a trivial overlay that publishes the built theme under
#      pkgs.keycloak-themes.keywind so downstream modules can reference it.
#
# Usage (flake or configuration.nix):
#
#   nixpkgs.overlays = [ (import ./default.nix).overlay ];
#
#   services.keycloak.themes = {
#     inherit (pkgs.keycloak-themes) keywind;
#   };
#
# then in a realm's login theme dropdown pick "keywind".

let
  # ---------------------------------------------------------------------------
  # The package itself.
  #
  # Pin `rev`/`hash`/`npmDepsHash` to a commit you have audited. The values
  # below are a working example; bump them for a newer Keywind and let Nix
  # tell you the correct hashes (build once with a fake hash, copy the
  # "got:" value nix prints).
  # ---------------------------------------------------------------------------
  keywindPackage =
    {
      lib,
      fetchFromGitHub,
      buildNpmPackage,
      nodejs,
      unzip,
      # Which Keycloak theme *type* to keep out of the built jar. Keywind ships
      # a login theme; keep it configurable in case an upstream fork adds more.
      themeType ? "login",
      # The theme name Keywind's build packs into the jar under theme/<name>/.
      # Upstream calls it "amora". This is an implementation detail of the
      # source, NOT the name users pick in Keycloak (that comes from the
      # attribute you inherit into services.keycloak.themes).
      themeName ? "amora",
    }:
    buildNpmPackage {
      pname = "keywind";
      version = "0.2.0";

      src = fetchFromGitHub {
        owner = "lukin";
        repo = "keywind";
        rev = "a47de9ed208521b2395d8a9edf9b8ef3b6654778";
        hash = "sha256-wl+Lma6bPtpuh5RXeDI15X3VZ6gdsiFP0jv/R3bySWs=";
      };

      npmDepsHash = "sha256-w4xlQSyCpmv1bF8Igcr9t3q0UBwEynOkYTi+TfC13CA=";

      buildInputs = [ nodejs ];

      # Two steps: `build` compiles the Tailwind/FreeMarker assets, `build:jar`
      # packs them into out/keywind.jar (a standard Keycloak theme jar).
      buildPhase = ''
        runHook preBuild
        npm run build
        npm run build:jar
        runHook postBuild
      '';

      # THE TRAP / the whole point of this recipe:
      #
      # `services.keycloak.themes.<name> = pkg;` expects `pkg` to be a directory
      # that IS a single theme flavour — i.e. the directory that contains
      # theme.properties, login/ templates, resources/, messages/ … . It does
      # NOT want the jar, and it does NOT want the jar's top-level `theme/`
      # wrapper with an intermediate <name>/ directory.
      #
      # Keycloak's own theme jar layout is:  theme/<themeName>/<themeType>/...
      # We unzip the jar and copy ONLY theme/<themeName>/<themeType> to $out.
      # That inner <themeType> (login) directory is the entire output Keycloak
      # actually consumes. Ship the wrapper and Keycloak silently fails to find
      # the theme.
      installPhase = ''
        runHook preInstall

        mkdir target
        ${unzip}/bin/unzip out/keywind.jar -d target
        rm -rf out

        mkdir $out
        cp -a target/theme/${themeName}/${themeType} $out

        runHook postInstall
      '';

      meta = with lib; {
        description = "A Tailwind.css theme for Keycloak";
        homepage = "https://github.com/lukin/keywind";
        license = licenses.asl20;
        platforms = platforms.all;
      };
    };

  # ---------------------------------------------------------------------------
  # The overlay. Publishes pkgs.keycloak-themes.keywind.
  # ---------------------------------------------------------------------------
  overlay = final: _prev: {
    keycloak-themes = (_prev.keycloak-themes or { }) // {
      keywind = final.callPackage keywindPackage { };
    };
  };
in
{
  inherit keywindPackage overlay;

  # Convenience: `(import ./default.nix).default` gives the plain package,
  # buildable with `nix-build -A default` against a pkgs set via callPackage,
  # or just import the overlay above.
  default = keywindPackage;
}
