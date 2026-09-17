let
  keywindPackage =
    {
      lib,
      fetchFromGitHub,
      buildNpmPackage,
      nodejs,
      unzip,
      themeType ? "login",
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

      buildPhase = ''
        runHook preBuild
        npm run build
        npm run build:jar
        runHook postBuild
      '';

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

  overlay = final: _prev: {
    keycloak-themes = (_prev.keycloak-themes or { }) // {
      keywind = final.callPackage keywindPackage { };
    };
  };
in
{
  inherit keywindPackage overlay;

  default = keywindPackage;
}
