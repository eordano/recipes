# js-workspace-package — package a pnpm / npm WORKSPACE (monorepo) with Nix.
#
# Three worked, buildable examples of the same shape: a two-package monorepo
# whose leaf package depends on a sibling workspace package AND on a registry
# package, built entirely offline from a pinned dependency set.
#
#   pnpmWorkspaceExample   fetchPnpmDeps + pnpmConfigHook + pnpmBuildHook
#   npmWorkspaceExample    buildNpmPackage + npmWorkspace + npmDepsFetcherVersion
#   npmImportLockExample   buildNpmPackage + importNpmLock (no hash at all)
#
# Build them (nixpkgs 26.11 / nixos-unstable):
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./default.nix {}' \
#     -A pnpmWorkspaceExample
#
# THE CORE FACT everything below follows from: the Nix build sandbox has NO
# NETWORK. `npm install` / `pnpm install` inside a normal derivation cannot
# reach a registry, so the dependency download has to happen in a separate
# fixed-output derivation whose content hash you pin by hand. Every knob here
# exists to make that FOD reproducible.
#
# See README.md for the traps. The short list:
#   * fetchPnpmDeps has NO default fetcherVersion and hard-asserts on it;
#     versions 1 and 2 were REMOVED in 26.11, and 3 is rejected for pnpm_11
#     (which is what plain `pnpm` is), so the default pnpm needs exactly 4.
#   * pnpm.fetchDeps / pnpm.configHook are deprecated shims that print a
#     lib.warn on evaluation. Use the top-level fetchPnpmDeps/pnpmConfigHook.
#   * fetchNpmDeps ALSO has a `fetcherVersion`, with completely different
#     semantics and a default of 1. Workspaces generally need 2.
#   * pnpmConfigHook runs `pnpm install --ignore-scripts` and never rebuilds:
#     native addons are NOT compiled for you the way buildNpmPackage does it.
#   * pnpm_9 / pnpm_10_29_2 / pnpm_10_34_0 carry knownVulnerabilities and will
#     refuse to evaluate without permittedInsecurePackages.
{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpmBuildHook,
  # Pin the pnpm MAJOR. `pkgs.pnpm` is an alias that moves under you and
  # changes the store format (and therefore every pnpmDeps hash) when it does.
  pnpm_11,
  nodejs,
  makeWrapper,
  buildNpmPackage,
  importNpmLock,
}:
let
  pnpm = pnpm_11;

  # The two workspace member names, exactly as they appear in each member's
  # package.json "name". pnpm --filter matches on the package NAME, not on the
  # directory.
  #
  # BOTH members are listed on purpose. `--filter=@example/cli` alone selects
  # only that project; the sibling it links to is resolved as a link, but the
  # sibling's OWN registry dependency (is-odd) is never fetched. Measured, both
  # failure shapes:
  #   * filter narrow in BOTH places  -> FOD produces an EMPTY pnpm store, the
  #     build succeeds, and the sibling is simply broken at runtime.
  #   * filter narrow in the FETCHER only -> build dies with
  #     [ERR_PNPM_NO_OFFLINE_TARBALL] ... may be downloaded from
  #     https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz
  #     and pnpmConfigHook's own hint tells you to regenerate the hash, which
  #     is the wrong fix — the hash is right, the filter is wrong.
  pnpmWorkspaces = [
    "@example/cli"
    "@example/util"
  ];
in
{
  ##########################################################################
  # 1. pnpm workspace.
  #
  # There is no `buildPnpmPackage` in nixpkgs. You assemble it yourself out of
  # stdenv.mkDerivation + three pieces: the FOD (fetchPnpmDeps), the config
  # hook (unpacks the FOD into a store dir and runs `pnpm install --offline`)
  # and optionally the build hook (`pnpm run <script>`).
  ##########################################################################
  pnpmWorkspaceExample = stdenv.mkDerivation (finalAttrs: {
    pname = "example-pnpm-cli";
    version = "1.0.0";

    src = ./example-pnpm;

    nativeBuildInputs = [
      nodejs # for anything that shells out to `node` outside a pnpm call
      pnpm # pnpmConfigHook only *propagates* sqlite/zstd, not pnpm itself
      pnpmConfigHook
      pnpmBuildHook
      makeWrapper
    ];

    # `pnpmWorkspaces` is read by BOTH hooks (as --filter=) and by the fetcher.
    # It must be identical in all three places or the offline install sees a
    # store that was populated for a different project set.
    inherit pnpmWorkspaces;

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src pnpmWorkspaces;
      # Pin the pnpm used to POPULATE the store to the same one that reads it.
      inherit pnpm;
      # Mandatory. No default. 1 and 2 were removed in 26.11; 3 is rejected for
      # pnpm_11. See README trap 2.
      fetcherVersion = 4;
      hash = "sha256-cnrJCL+ZkGR2kcjSzFdOwmUExhX2F/JDtLzG/NwAiH4=";
    };

    # pnpmBuildHook runs: pnpm run --filter=... "$pnpmBuildScript"
    pnpmBuildScript = "build";

    # pnpm's node_modules is a forest of RELATIVE symlinks into
    # node_modules/.pnpm at the workspace root, plus links to sibling
    # workspace members. It is not relocatable file-by-file, so install the
    # whole tree and wrap an entry point rather than copying `dist/` alone.
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

  ##########################################################################
  # 2. npm workspace via buildNpmPackage.
  #
  # buildNpmPackage hides the FOD: pass `npmDepsHash` and it calls
  # fetchNpmDeps for you. `npmWorkspace` is threaded into `npm run`,
  # `npm pack` and `npm prune`, so the leaf package is what gets installed.
  ##########################################################################
  npmWorkspaceExample = buildNpmPackage (finalAttrs: {
    pname = "example-npm-cli";
    version = "1.0.0";

    src = ./example-npm;

    # THE hash. Obtain it WITHOUT a build round-trip — but you must pass the
    # fetcher version through the environment, because the CLI reads
    # NPM_FETCHER_VERSION, not a flag (prefetch-npm-deps/src/main.rs:471-478):
    #
    #   NPM_FETCHER_VERSION=2 prefetch-npm-deps example-npm/package-lock.json
    #
    # Forgetting the env var yields the v1 hash and a plain FOD hash mismatch.
    # Measured on this fixture: v1 = sha256-uyswbNOnaX5j0XZEBDkg+Qg5TrOhZZDJOuXUOoomN38=,
    # v2 = the value below.
    npmDepsHash = "sha256-LjjOtJ97AigZUIuumfFin4eObtl1w7vhzZdC01SARbY=";

    # Workspace support in the npm cache: version 2 additionally caches
    # *packuments* (registry metadata documents), which `npm ci` demands when
    # a workspace member resolves a sibling by version range. Default is 1.
    # Changing it invalidates npmDepsHash.
    npmDepsFetcherVersion = 2;

    # Directory (not package name) of the workspace member to build+install.
    # Directory (not package name) of the workspace member to build+install.
    npmWorkspace = "packages/cli";
    npmBuildScript = "build";

    # THE npmWorkspace TRAP. npmInstallHook copies the ROOT node_modules into
    # the output (build-npm-package/hooks/npm-install-hook.sh:39) and names the
    # output directory after the ROOT package.json's `.name` (line 8, `jq
    # --raw-output '.name' package.json` — not $npmWorkspace/package.json).
    # That root node_modules contains a `link: true` entry per workspace
    # member pointing at ../../packages/<member>, which is NOT copied. Result:
    # dangling symlinks, and stdenv's noBrokenSymlinks fixup hook FAILS the
    # build with "found 3 dangling symlinks".
    #
    # Two upstream remedies, both hand-rolled in postInstall:
    #   * materialise the targets  (pkgs/by-name/js/jsdoc/package.nix:30-33)
    #   * delete the links         (pkgs/by-name/mc/mcp-server-memory/package.nix:27-34)
    # We materialise, because the CLI resolves its sibling through them.
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

  ##########################################################################
  # 3. Same npm workspace, NO hash to maintain.
  #
  # importNpmLock reads package-lock.json at EVAL time and turns each
  # `resolved` URL into its own fetchurl, keyed by the `integrity` field that
  # is already in the lockfile. Nothing to pin, nothing to regenerate — at the
  # cost of one derivation per dependency and import-from-lockfile evaluation.
  #
  # npmHooks.npmConfigHook does NOT work here; importNpmLock ships its own.
  ##########################################################################
  npmImportLockExample = buildNpmPackage {
    pname = "example-npm-cli-importlock";
    version = "1.0.0";

    src = ./example-npm;

    npmDeps = importNpmLock { npmRoot = ./example-npm; };
    npmConfigHook = importNpmLock.npmConfigHook;

    npmWorkspace = "packages/cli";
    npmBuildScript = "build";

    # Same dangling-symlink trap as above — it is a property of npmInstallHook
    # and npm workspaces, not of the fetcher you chose.
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
