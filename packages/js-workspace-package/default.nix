{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpmBuildHook,
  pnpm_11,
  nodejs,
  makeWrapper,
  buildNpmPackage,
  importNpmLock,
}:
let
  pnpm = pnpm_11;

  pnpmWorkspaces = [
    "@example/cli"
    "@example/util"
  ];
in
{
  pnpmWorkspaceExample = stdenv.mkDerivation (finalAttrs: {
    pname = "example-pnpm-cli";
    version = "1.0.0";

    src = ./example-pnpm;

    nativeBuildInputs = [
      nodejs
      pnpm
      pnpmConfigHook
      pnpmBuildHook
      makeWrapper
    ];

    inherit pnpmWorkspaces;

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs)
        pname
        version
        src
        pnpmWorkspaces
        ;
      inherit pnpm;
      fetcherVersion = 4;
      hash = "sha256-cnrJCL+ZkGR2kcjSzFdOwmUExhX2F/JDtLzG/NwAiH4=";
    };

    pnpmBuildScript = "build";

    installPhase = ''
      runHook preInstall

      mkdir -p $out/libexec $out/bin
      cp -R . $out/libexec/${finalAttrs.pname}

      makeWrapper ${lib.getExe nodejs} $out/bin/example-cli \
        --add-flags $out/libexec/${finalAttrs.pname}/packages/cli/dist/cli.js

      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      got=$($out/bin/example-cli 7)
      echo "example-cli 7 -> $got"
      [ "$got" = "7 is odd" ]

      runHook postInstallCheck
    '';

    meta = {
      description = "Worked example: pnpm workspace packaged offline with fetchPnpmDeps";
      license = lib.licenses.cc0;
      mainProgram = "example-cli";
      platforms = lib.platforms.all;
    };
  });

  npmWorkspaceExample = buildNpmPackage (_finalAttrs: {
    pname = "example-npm-cli";
    version = "1.0.0";

    src = ./example-npm;

    npmDepsHash = "sha256-LjjOtJ97AigZUIuumfFin4eObtl1w7vhzZdC01SARbY=";

    npmDepsFetcherVersion = 2;

    npmWorkspace = "packages/cli";
    npmBuildScript = "build";

    postInstall = ''
      mkdir -p $out/lib/node_modules/example-npm-monorepo/packages
      cp -R packages/. $out/lib/node_modules/example-npm-monorepo/packages/
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      got=$($out/bin/example-npm-cli 7)
      echo "example-npm-cli 7 -> $got"
      [ "$got" = "7 is odd" ]

      runHook postInstallCheck
    '';

    meta = {
      description = "Worked example: npm workspace packaged offline with buildNpmPackage";
      license = lib.licenses.cc0;
      mainProgram = "example-npm-cli";
      platforms = lib.platforms.all;
    };
  });

  npmImportLockExample = buildNpmPackage {
    pname = "example-npm-cli-importlock";
    version = "1.0.0";

    src = ./example-npm;

    npmDeps = importNpmLock { npmRoot = ./example-npm; };
    inherit (importNpmLock) npmConfigHook;

    npmWorkspace = "packages/cli";
    npmBuildScript = "build";

    postInstall = ''
      mkdir -p $out/lib/node_modules/example-npm-monorepo/packages
      cp -R packages/. $out/lib/node_modules/example-npm-monorepo/packages/
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      got=$($out/bin/example-npm-cli 7)
      echo "example-npm-cli 7 -> $got"
      [ "$got" = "7 is odd" ]

      runHook postInstallCheck
    '';

    meta = {
      description = "Worked example: npm workspace packaged with importNpmLock (hashless)";
      license = lib.licenses.cc0;
      mainProgram = "example-npm-cli";
      platforms = lib.platforms.all;
    };
  };
}
