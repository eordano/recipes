# js-workspace-package

Package a **pnpm or npm workspace** (a JS monorepo) with Nix: three worked,
buildable examples of a two-package monorepo whose leaf package depends on a
sibling workspace member *and* on a registry package, built entirely offline.

All three build and self-check against nixpkgs `nixos-unstable` (`.version`
**26.11**), `nodejs` 24.18.0, `pnpm` 11.15.0:

```
nix-build -E 'with import <nixpkgs> {}; callPackage ./default.nix {}' \
  -A pnpmWorkspaceExample     # fetchPnpmDeps + pnpmConfigHook + pnpmBuildHook
  -A npmWorkspaceExample      # buildNpmPackage + npmWorkspace
  -A npmImportLockExample     # buildNpmPackage + importNpmLock (no hash)
```

Each one ends in an `installCheckPhase` that actually runs the produced CLI and
asserts its output, so "it built" means "it works", not "it linked".

## Why this is a `packages/` recipe, not an `overlays/` one

The two categories answer different questions, and this one is squarely the
first:

- **`overlays/` is for changing a package that already exists.** Every overlay
  recipe in this collection takes a nixpkgs attribute and rewrites it —
  `go-vendor-patch-prefix-rewrite` re-prefixes a patch so it applies inside a
  vendored Go tree, `skip-flaky-tests-overlay` disables a check,
  `electron-bin-override` swaps a from-source build for the prebuilt one. They
  are all shaped `final: prev: { foo = prev.foo.overrideAttrs … }`. There is no
  nixpkgs attribute here to override: the subject is *your* monorepo, which
  nixpkgs has never heard of.
- **`packages/` is for a derivation you write from scratch**, and that is
  exactly the deliverable — `stdenv.mkDerivation` / `buildNpmPackage` calls that
  turn a source tree into a package.

The tiebreaker is that the recipe must be **buildable to be trustworthy**. The
claims below are about hash layouts, fetcher-version asserts and hook ordering,
and the only honest way to make them is to run them. A `packages/` recipe is
picked up by the flake's `packagesOverlay` and exposed as
`packages.<system>.js-workspace-package`, so `nix build` checks the prose on
every evaluation. An overlay recipe has nothing to build.

Like `go-vendor-patch-prefix-rewrite`, this is a **technique** recipe: the
fixtures are here to be read and copied, not consumed. Nobody should depend on
`example-pnpm-cli`.

## The problem

### The build sandbox has no network

That is the whole story. Every other design decision follows from it. Run a
plain `npm install` inside a normal derivation and you get, verbatim:

```
npm error code EAI_AGAIN
npm error syscall getaddrinfo
npm error errno EAI_AGAIN
npm error request to https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz failed,
  reason: getaddrinfo EAI_AGAIN registry.npmjs.org
```

So the download has to move into a separate **fixed-output derivation** (FOD),
which is the only kind of derivation allowed to reach the network — in exchange
for you pinning its output hash by hand. Everything below is about making that
FOD's output byte-identical across machines and across time, because the moment
it is not, your hash rots and every consumer's build breaks.

nixpkgs gives you three ways to do it. They are **not** interchangeable.

| | fetcher | hash to maintain | derivations | workspace support |
| --- | --- | --- | --- | --- |
| pnpm | `fetchPnpmDeps` | 1 | 1 FOD | `pnpmWorkspaces` (`--filter`) |
| npm | `fetchNpmDeps` (via `buildNpmPackage`'s `npmDepsHash`) | 1 | 1 FOD | `npmWorkspace` + `npmDepsFetcherVersion = 2` |
| npm | `importNpmLock` | **none** | one `fetchurl` per dependency | inherited from the lockfile |

### What upstream nixpkgs does NOT give you

**There is no `buildPnpmPackage`.** `pkgs/top-level/all-packages.nix:2786-2789`
exposes exactly two names from the pnpm build support — `fetchPnpmDeps` and
`pnpmConfigHook` — and nothing wraps them into a builder. `pnpmBuildHook`
exists but lives out of the way in `pkgs/by-name/pn/pnpmBuildHook/package.nix`
and is a bare `makeSetupHook`. You assemble `stdenv.mkDerivation` yourself. The
npm side, by contrast, *does* have `buildNpmPackage`
(`all-packages.nix:2419`).

**There is no `prefetch-pnpm-deps`.** `all-packages.nix:473` gives you
`prefetch-yarn-deps` and `:2425` gives you `prefetch-npm-deps`; there is no pnpm
equivalent. For pnpm the only way to obtain a hash is the fake-hash round trip.

## Traps

### Trap 1 — pick the fetcher from the lockfile, not from taste

`prefetch-npm-deps` parses `lockfileVersion` and hard-`bail!`s on anything it
does not know
(`pkgs/build-support/node/prefetch-npm-deps/src/parse/lock.rs:43-77`):

- `1` → the ancient `dependencies` tree, converted internally.
- `2 | 3` → the modern flat `packages` map.
- anything else → `We don't support lockfile version N, please file an issue.`

`importNpmLock` is stricter and fails *at evaluation*, not at build. It reads
`packageLock.packages` unconditionally
(`pkgs/build-support/node/import-npm-lock/default.nix:145`), and a
`lockfileVersion: 1` file has no `packages` key at all. Measured:

```
error: attribute 'packages' missing
at …/pkgs/build-support/node/import-npm-lock/default.nix:145:11
```

There is no hint in that message that your lockfile is the problem. **If you
see it, run `npm install --package-lock-only` upstream and commit a v2/v3
lockfile.**

For pnpm, `fetchPnpmDeps` guards the pnpm major against the lockfile — badly.
`pkgs/build-support/node/fetch-pnpm-deps/default.nix:103-107`:

```bash
lockfileVersion="$(yq -r .lockfileVersion pnpm-lock.yaml)"
if [[ ${lockfileVersion:0:1} -gt <pnpm major> ]]; then
```

`${lockfileVersion:0:1}` is the **first character**. For today's `'9.0'` that is
`9` and the check works. The day pnpm writes a two-digit lockfile version, `10`
truncates to `1` and the guard silently passes for every pnpm major. Do not rely
on it; pin the pnpm major deliberately.

### Trap 2 — `fetchPnpmDeps` has no default `fetcherVersion`, and only one legal value for the default pnpm

This is the single most likely thing to stop you. Four asserts, in order
(`fetch-pnpm-deps/default.nix:56-70`):

```nix
assert fetcherVersion != null || throw "fetchPnpmDeps: `fetcherVersion` is not set…";
assert !(fetcherVersion == 1 || fetcherVersion == 2)
       || throw "… was removed in the 26.11 release…";
assert builtins.elem fetcherVersion [ 3 4 ] || throw "…not a supported value…";
assert !(fetcherVersion == 3 && lib.versionAtLeast pnpm.version "11.0.0")
       || throw "… `fetcherVersion = 3` is no longer supported for `pnpm_11`…";
```

Combine that with `all-packages.nix:2784`, `pnpm = pnpm_11`, and the conclusion
is: **with the default `pnpm`, `fetcherVersion = 4` is the only value that
evaluates.** Every copy-pasted `fetcherVersion = 1` or `2` from a pre-26.11
blog post is now an eval error, and every `fetcherVersion = 3` example is an
eval error unless it *also* pins `pnpm_10` or older.

`fetcherVersion` is not cosmetic — it changes the FOD's on-disk layout and
therefore the hash:

- **3** builds a reproducible zstd tarball of the pnpm store.
- **4** additionally dumps pnpm 11's `index.db` SQLite file to a text SQL dump
  and rebuilds it at install time, because SQLite's binary format embeds a
  non-deterministic `version-valid-for` counter
  (`fetch-pnpm-deps/default.nix:166-181`, `pnpm-config-hook.sh:62-65`).

There is even a SQLite-version workaround inside that: SQLite ≥ 3.53.0 changed
BLOB literals in `.dump` output from `X'…'` to `x'…'`, so the fetcher `sed`s
them back to keep old hashes valid (`default.nix:174-180`). Bumping your nixpkgs
across that boundary would otherwise have invalidated every pnpm hash in the
tree.

### Trap 3 — `pnpm.fetchDeps` and `pnpm.configHook` are deprecated shims

Most examples on the internet still use them. In 26.11 they are wrapped in
`lib.warn` and print on every evaluation
(`pkgs/development/tools/pnpm/generic.nix:99-120`):

```
pnpm.fetchDeps: The package attribute is deprecated.
  Use the top-level fetchPnpmDeps attribute instead
```

Use the top-level `fetchPnpmDeps` / `pnpmConfigHook` and pass `pnpm = pnpm_11;`
explicitly. Related: `pnpmDeps.passthru.serve` is now a `throw`
(`fetch-pnpm-deps/default.nix:219`, removed 2026-06-04).

### Trap 4 — three of the five pnpm majors refuse to evaluate

`pkgs/development/tools/pnpm/default.nix` marks `pnpm_9` (9.15.9),
`pnpm_10_29_2` and `pnpm_10_34_0` with `knownVulnerabilities` (lines 12-23,
31-42, 49-57). The advice "pin a pnpm major for reproducibility" therefore
collides with "that major is embargoed". Asking for `pnpm_9.drvPath` gives:

```
error: Refusing to evaluate package 'pnpm-9.15.9' in
  …/pkgs/development/tools/pnpm/generic.nix:164 because it is marked as insecure
Known issues:
 - CVE-2026-48995
 - CVE-2026-50014
 …
```

Only `pnpm_10` (10.34.5) and `pnpm_11` (11.15.0) evaluate clean. If you
genuinely need an older store format you must add the exact `pnpm-<version>`
string to `nixpkgs.config.permittedInsecurePackages` — and note that
`permittedInsecurePackages` set in *your* flake does **not** reach a package
defined inside an *input* flake that instantiates its own nixpkgs.

### Trap 5 — the workspace filter must be identical in all three places, and an over-narrow one succeeds silently

`pnpmWorkspaces` is consumed three times:

- by the fetcher, as `--filter=` on the online `pnpm install`
  (`fetch-pnpm-deps/default.nix:50`, `:143-149`);
- by `pnpmConfigHook`, as `--filter=` on the **offline** install
  (`pnpm-config-hook.sh:75-80`);
- by `pnpmBuildHook`, as `--filter=` on `pnpm run`
  (`pkgs/by-name/pn/pnpmBuildHook/pnpm-build-hook.sh:20-24`).

`--filter` matches the **package name** from each member's `package.json`, not
the directory. Two measured failure shapes:

1. **Narrow in both places.** Filter to just the leaf `@example/cli`, whose only
   dependency is a `workspace:*` link. The FOD downloads *nothing* and the build
   succeeds — with a pnpm store that is empty and a sibling that is broken at
   runtime. The empty-store hash is a stable, recognisable fingerprint: this
   fixture produced `sha256-dIp6CNh1Kn4aqJWku1G/FUdn/u+epzhqlqwnAkB2uW0=`, which
   is byte-for-byte the hash nixpkgs' own unrelated workspace test pins at
   `pkgs/test/pnpm/pnpm-workspaces/default.nix:21` — because that test's members
   also have no registry dependencies. **If your `pnpmDeps` hash equals another
   project's, your filter selected nothing.** (The fingerprint is per pnpm-major
   *and* per fetcherVersion: the pnpm 10 / fetcherVersion 3 empty store is
   `sha256-u0GOAX5B1f2ANWbOezScp/eKQRRZA/JoYfQ5zLrNip4=`,
   `pkgs/test/pnpm/pnpm-empty-lockfile/default.nix:24`.)

2. **Narrow in the fetcher only.** The offline install then wants a tarball the
   store never got:

   ```
   [ERR_PNPM_NO_OFFLINE_TARBALL] A package is missing from the store but cannot
   download it in offline mode. The missing package may be downloaded from
   https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz
   ```

   `pnpmConfigHook` then prints its stock advice — "Set pnpmDeps.hash to an
   empty string, rebuild, copy the new hash"
   (`pnpm-config-hook.sh:96-101`). **That advice is wrong for this failure.**
   The hash is correct for the filter you asked for; the filter is what is
   wrong. Following the hint bakes the broken dependency set into a new hash and
   the build fails again identically.

The fix is to list every member whose dependencies the build actually needs —
including siblings reached through `workspace:*` links. `pnpmWorkspaces = [
"@example/cli" "@example/util" ]` in `default.nix`, `inherit`ed into
`fetchPnpmDeps`, is the shape to copy.

### Trap 6 — npm workspaces need `npmDepsFetcherVersion = 2`, and the env var to prefetch it

`fetchNpmDeps` has its **own** `fetcherVersion`, unrelated in both numbering and
meaning to pnpm's, defaulting to `1`
(`pkgs/build-support/node/prefetch-npm-deps/default.nix:240-243`):

```nix
# Fetcher format version. Bump this to invalidate all existing hashes.
# Version 1: original format (tarballs only)
# Version 2: includes packuments for workspace support
fetcherVersion ? 1,
```

A *packument* is the registry's per-package metadata document. `npm ci` asks for
one whenever a workspace member resolves a sibling by version range; with
version 1 the cache holds none and `npm ci` fails offline — which is exactly why
the hook's own failure text leads with "1. Set `npmDepsFetcherVersion = 2` (and
update `npmDepsHash`)" (`hooks/npm-config-hook.sh:126-133`). Version 2 fetches
and caches them under both the `corgiDoc` and `fullDoc` `Accept` headers
(`src/main.rs:158-186`). Surface it through `buildNpmPackage` as
`npmDepsFetcherVersion` (`build-npm-package/default.nix:29-31`), which also
exports `NIX_NPM_FETCHER_VERSION` so `npmConfigHook` can cross-check it against
the `.fetcher-version` file in the cache and tell you the hash is stale rather
than letting npm fail cryptically (`hooks/npm-config-hook.sh:31-52`).

Getting the hash **without** a build round-trip needs the environment variable,
because the CLI has no flag for it (`src/main.rs:471-478`):

```console
$ NPM_FETCHER_VERSION=2 prefetch-npm-deps package-lock.json
sha256-LjjOtJ97AigZUIuumfFin4eObtl1w7vhzZdC01SARbY=
$ prefetch-npm-deps package-lock.json          # forgot it → v1 layout
sha256-uyswbNOnaX5j0XZEBDkg+Qg5TrOhZZDJOuXUOoomN38=
```

Those are the two hashes for the *same* lockfile. Use the wrong one and you get
a plain FOD hash mismatch that says nothing about fetcher versions.

Version 2 also silently costs you the read-only cache optimisation: with more
than one entry per cache key npm always needs to write, so `npmConfigHook`
copies the whole cache into `$TMPDIR` regardless of `makeCacheWritable`
(`hooks/npm-config-hook.sh:108-115`).

### Trap 7 — the "more than 50% of packages are missing 'resolved' URLs" warning is a false alarm on every workspace

Workspace members appear in `package-lock.json` as `"link": true` entries with
no `resolved` URL. `prefetch-npm-deps` counts them as unfetchable and, past a
50% threshold, prints advice to regenerate the lockfile
(`src/parse/lock.rs:13-41`). On this two-member fixture:

```
warning: 4 out of 6 packages (66.7%) are missing 'resolved' URLs and will not be cached.
warning: Packages without 'resolved' URLs:
warning:   - @example-npm/util
warning:   - packages/cli
warning:   - @example-npm/cli
warning:   - packages/util
warning: More than 50% of packages are missing 'resolved' URLs. …
warning: Consider regenerating upstream's lockfile with: npm install --package-lock-only
```

Every one of those four is a workspace link that is *supposed* to have no URL.
The smaller the monorepo, the louder the false alarm. Read the *list*, not the
percentage: if the named packages are all your own members, ignore it.

The list is emitted from a `rayon` parallel partition, so **the order of those
names changes between runs** on the same lockfile — two consecutive invocations
here printed the same four members in two different orders. Do not diff this
warning block in CI, and do not treat a reordering as a lockfile change.
Only the first 10 are shown, with `... and N more` past that
(`src/parse/lock.rs:29-33`).

### Trap 8 — `npmWorkspace` produces dangling symlinks and stdenv fails the build

This one bites every npm workspace whose leaf depends on a sibling, and it is
not documented anywhere in the manual.

`npmInstallHook` does two things that do not compose:

- it names the output directory after the **root** `package.json`'s `.name` —
  `jq --raw-output '.name' package.json`, with no `$npmWorkspace` prefix
  (`build-npm-package/hooks/npm-install-hook.sh:8`);
- it copies the **root** `node_modules` wholesale into that directory
  (`:39`), and the root `node_modules` of any npm workspace contains one
  symlink per member pointing at `../../packages/<member>` — which is never
  copied.

stdenv's `noBrokenSymlinks` fixup hook then kills the build:

```
ERROR: noBrokenSymlinks: the symlink …/node_modules/@example-npm/cli points to a
  missing target: …/example-npm-monorepo/packages/cli
ERROR: noBrokenSymlinks: the symlink …/node_modules/.bin/example-npm-cli points to a
  missing target: …/node_modules/@example-npm/cli/dist/cli.js
ERROR: noBrokenSymlinks: found 3 dangling symlinks, 0 reflexive symlinks and 0 unreadable symlinks
```

It is fetcher-independent: `importNpmLock` reproduces it identically.

nixpkgs has no fix, only per-package `postInstall` workarounds, in two flavours:

- **Materialise the targets.** `pkgs/by-name/js/jsdoc/package.nix:29-32` does
  `mkdir -p $out/lib/node_modules/jsdoc/packages; mv packages/* …`. Keeps the
  links working, so the leaf can still `require()` its sibling.
- **Delete the links.** `pkgs/by-name/mc/mcp-server-memory/package.nix:27-34`
  `rm -rf`s each `node_modules/@modelcontextprotocol/server-*` plus
  `node_modules/.bin`, with a `TODO` to revisit it once nixpkgs PR #333759 has
  landed. Only safe when
  nothing actually resolves through them.

Both examples here materialise, because the CLI genuinely resolves its sibling
through the link — and the `installCheckPhase` proves it by running the binary.

### Trap 9 — pnpm never rebuilds native modules for you; npm does

The asymmetry is easy to miss and it is why a package with a `node-gyp` addon
"works with buildNpmPackage" and mysteriously does not with pnpm.

`buildNpmPackage`'s `npmConfigHook`:

- exports `npm_config_nodedir`, `npm_config_node_gyp`, `npm_config_arch`,
  `npm_config_platform` (`hooks/npm-config-hook.sh:17-20`);
- adds `nodejs.python` to `nativeBuildInputs`
  (`build-npm-package/default.nix:104`) — node-gyp needs a Python;
- runs `npm ci --ignore-scripts`, then **`npm rebuild`**, then `patchShebangs`
  twice (`:125-143`).

`pnpmConfigHook` exports `npm_config_arch` / `npm_config_platform` (plus the
`pnpm_config_*` spellings) and nothing else (`pnpm-config-hook.sh:50-53`), then
runs `pnpm install --offline --ignore-scripts` and stops (`:88-92`). No rebuild
and no `npm_config_nodedir`. It cannot give you a Python either: its whole
`propagatedBuildInputs` is `[ sqlite writableTmpDirAsHomeHook zstd ]`
(`fetch-pnpm-deps/default.nix:231-237`) — compare `nodejs.python` sitting in
`buildNpmPackage`'s at `build-npm-package/default.nix:104`. The
fetcher goes further and sets `side-effects-cache=false` precisely so that
platform-dependent build products never enter the hashed store
(`fetch-pnpm-deps/default.nix:121-128`).

So under pnpm you do it yourself. Upstream precedent:

```nix
preBuild = ''
  export npm_config_nodedir=${nodejs}
  pnpm rebuild bcrypt sqlite3          # or: pnpm rebuild            (whole tree)
'';
nativeBuildInputs = [ nodejs pnpm pnpmConfigHook python3 ];
```

`pkgs/by-name/se/seerr/package.nix:53` (named modules),
`pkgs/by-name/sh/sharkey/package.nix:85` (whole tree),
`pkgs/by-name/se/session-desktop/package.nix:180`,
`pkgs/by-name/t3/t3code/unwrapped.nix:106` (`pnpm rebuild --pending` with a
negative filter), and `pkgs/by-name/si/signal-desktop/signal-sqlcipher.nix:59`
for the `npm_config_nodedir` export next to a `prebuildify` run.

### Trap 10 — a pnpm `node_modules` is not relocatable file-by-file

pnpm installs a symlink forest: `node_modules/<pkg>` points into
`node_modules/.pnpm/…` at the workspace root, and workspace members point at
each other with relative paths. `pnpmConfigHook` even forces
`package-import-method clone-or-copy` to survive filesystems without reflink
support (`pnpm-config-hook.sh:69-71`).

Copying only `packages/<leaf>/dist` into `$out` therefore ships a program that
cannot resolve any of its imports. The example here copies the **entire built
tree** into `$out/libexec` and wraps an entry point:

```nix
installPhase = ''
  mkdir -p $out/libexec $out/bin
  cp -R . $out/libexec/${finalAttrs.pname}
  makeWrapper ${lib.getExe nodejs} $out/bin/example-cli \
    --add-flags $out/libexec/${finalAttrs.pname}/packages/cli/dist/cli.js
'';
```

If you need a flat, copyable `node_modules` instead, force the hoisted linker —
but put it in the **right phase**, and note that upstream's best-known example
puts it in a different one on purpose.

Any pnpm setting that must apply to the fetched store belongs in
`prePnpmInstall`, because that is the one hook run by *both* sides: the fetcher
interpolates it before its online install (`fetch-pnpm-deps/default.nix:135`)
and `pnpmConfigHook` runs it before the offline one
(`pnpm-config-hook.sh:82`). Settings placed there keep the two installs in
agreement — and change the FOD's contents, so changing one invalidates
`pnpmDeps.hash`.

`pkgs/by-name/we/webeep-sync/package.nix:72` does **not** do that. Its
`pnpm config set node-linker hoisted` sits in `buildPhase`, after
`pnpmConfigHook` has already materialised the symlink forest — it re-links the
tree for packaging only, and has no effect on `pnpmDeps` or its hash. That
package defines no `prePnpmInstall` at all. Copy it if you want a flat tree at
*install* time; do not copy it expecting a hoisted *store*.

### Trap 11 — registries: two different mechanisms, and packuments ignore both

- **pnpm** takes the registry from the *impure* environment variable
  `NIX_NPM_REGISTRY`, listed in `impureEnvVars` and interpolated straight into
  the install (`fetch-pnpm-deps/default.nix:92-93`, `:148`). Being impure, it
  does not participate in the hash — two machines with different values can
  produce different stores under the same hash.
- **npm** takes a *pure* Nix argument: `npmRegistryOverridesString`, defaulting
  to `config.npmRegistryOverridesString`
  (`prefetch-npm-deps/default.nix:239`, `:300`), settable fleet-wide as
  `nixpkgs.config.npmRegistryOverrides = { "registry.npmjs.org" =
  "my-mirror.local/registry.npmjs.org"; }` (`pkgs/top-level/config.nix:177-192`).
  The rewrite happens per-URL in `src/util.rs:23-36`.
- **Packuments ignore the override for cache-key purposes.** `fetch_packuments`
  builds its URL from a hard-coded `https://registry.npmjs.org`
  (`src/main.rs:147`) and uses that same string as the cacache key
  (`:161`, `:176`). The override still redirects where the *bytes* come from,
  but a build whose `.npmrc` points npm at a private registry will look up a
  different key and miss. Private-registry workspaces are the case where
  `importNpmLock` — which uses ordinary `fetchurl` per dependency and no cache
  keys at all — is the easier answer.

Auth for private registries is `NIX_NPM_TOKENS`, a JSON map, also impure
(`prefetch-npm-deps/default.nix:295-297`).

### Trap 12 — `importNpmLock` trades the hash for evaluation cost and a `fetchGit`

`importNpmLock` reads `package-lock.json` at eval time and emits one fetcher per
dependency, keyed on the `integrity` field already in the lockfile
(`import-npm-lock/default.nix:25-76`). Nothing to pin, nothing to regenerate on
a dependency bump. The costs, in order of how much they hurt:

- **One derivation per dependency.** A 1500-package lockfile is 1500 fetchurls
  in your eval and your store.
- **`fetchGit` for git dependencies** (`:55-69`), which is impure-ish and
  ignores `fetcherOpts` you might expect `fetchgit` to honour.
- **`npmHooks.npmConfigHook` does not work with it** — you must pass
  `npmConfigHook = importNpmLock.npmConfigHook;`. `importNpmLock` ships its own
  (`:253-254`), and the manual states the incompatibility as a bare note under
  `#javascript-buildNpmPackage-importNpmLock` without saying what breaks. Since
  `buildNpmPackage` defaults `npmConfigHook` to the wrong one
  (`build-npm-package/default.nix:101`), omitting the override is the default
  behaviour, not an obvious mistake.
- It does **not** rescue you from Trap 8; the dangling-symlink failure is
  identical.

Its companion `importNpmLock.buildNodeModules` +
`importNpmLock.hooks.linkNodeModulesHook` is the good story for `nix develop`
shells (`:181-251`): `node_modules` gets symlinked from the store on shell
entry, and you use `npm install --package-lock-only` so npm only ever writes the
lockfile.

## Usage

### pnpm workspace

```nix
{ stdenv, fetchPnpmDeps, pnpmConfigHook, pnpmBuildHook, pnpm_11, nodejs, makeWrapper }:
let
  pnpm = pnpm_11;                     # pin the MAJOR, never bare `pkgs.pnpm`
in
stdenv.mkDerivation (finalAttrs: {
  pname = "my-app";
  version = "1.2.3";
  src = ./.;

  nativeBuildInputs = [ nodejs pnpm pnpmConfigHook pnpmBuildHook makeWrapper ];

  pnpmWorkspaces = [ "@scope/app" "@scope/shared" ];   # every member you need

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src pnpmWorkspaces;
    inherit pnpm;
    fetcherVersion = 4;               # only legal value with pnpm_11
    hash = "";                        # build once, copy the `got:` value
  };

  pnpmBuildScript = "build";
})
```

If the project lives in a subdirectory, set `sourceRoot` on `fetchPnpmDeps` and
`pnpmRoot` on the outer derivation to the *same* location — `pnpmConfigHook`
pushes into `$pnpmRoot` before installing (`pnpm-config-hook.sh:11-13`).

Extra pnpm settings go in `prePnpmInstall`, which must be passed to **both** the
fetcher and the derivation or the two installs disagree:

```nix
prePnpmInstall = "pnpm config set dedupe-peer-dependents false";
pnpmDeps = fetchPnpmDeps { inherit (finalAttrs) prePnpmInstall; /* … */ };
```

### npm workspace

```nix
buildNpmPackage (finalAttrs: {
  pname = "my-app";
  version = "1.2.3";
  src = ./.;

  npmDepsHash = "sha256-…";           # NPM_FETCHER_VERSION=2 prefetch-npm-deps …
  npmDepsFetcherVersion = 2;          # workspaces need packuments
  npmWorkspace = "packages/app";      # a DIRECTORY, not a package name
  npmBuildScript = "build";

  postInstall = ''                    # Trap 8
    mkdir -p $out/lib/node_modules/<root-package-name>/packages
    cp -R packages/. $out/lib/node_modules/<root-package-name>/packages/
  '';
})
```

`<root-package-name>` is `.name` from the **root** `package.json`, which is what
`npmInstallHook` used to name the output directory.

### Getting a hash

```console
# npm — no build needed
$ NPM_FETCHER_VERSION=2 prefetch-npm-deps package-lock.json

# pnpm — no prefetcher exists; use the round trip
$ # set hash = ""; (or lib.fakeHash), build, and read:
  hash mismatch in fixed-output derivation '…-my-app-pnpm-deps.drv':
           specified: sha256-AAAA…
              got:    sha256-cnrJCL+ZkGR2kcjSzFdOwmUExhX2F/JDtLzG/NwAiH4=
```

`hash = ""` is handled explicitly by both fetchers — it becomes
`outputHash = ""; outputHashAlgo = "sha256";`
(`fetch-pnpm-deps/default.nix:41-48`, `prefetch-npm-deps/default.nix:247-256`) —
and `fetchNpmDeps` uses the empty/fake hash as the signal to trust the real CA
bundle instead of a bogus `/no-cert-file.crt`
(`prefetch-npm-deps/default.nix:306-317`).

## Files

| path | what it is |
| --- | --- |
| `default.nix` | the three worked examples, callPackage-able |
| `example-pnpm/` | 2-member pnpm workspace + `pnpm-workspace.yaml` + `pnpm-lock.yaml` (v9.0) |
| `example-npm/` | the same shape as npm workspaces + `package-lock.json` (v3) |

Each leaf CLI `require()`s its sibling, which in turn `require()`s a real
registry package (`is-odd`), so all three axes — workspace link, transitive
registry dependency, offline install — are exercised by one 20-line program.

## Related recipes

- [`electron-bin-override`](../overlays/electron-bin-override.md) — the other
  half of packaging a desktop JS app: skip the from-source Electron build.
- [`deno-compile-reproducible`](../overlays/deno-compile-reproducible.md) — the
  same no-network-in-the-sandbox problem, solved for Deno's lazy remote imports.
- [`aarch64-native-webassets-overlay`](../overlays/aarch64-native-webassets-overlay.md)
  — when the JS toolchain itself must not run under emulation.

## Caveats

- **These examples are technique demonstrations, not packages you want.** They
  build a toy CLI. Copy the structure, not the fixture.
- **Nothing in this recipe touches a NixOS module.** It is package-level only;
  there is no option namespace, no service, no system closure impact.
- **Everything is pinned to nixpkgs 26.11 semantics.** The `fetcherVersion`
  arithmetic in particular is release-specific: 1 and 2 were removed *in this
  release*, and 3 was retired for `pnpm_11` *in this release*. Read
  `fetch-pnpm-deps/default.nix:19-70` in whatever nixpkgs you actually use
  before copying a number out of here.
- **Do not use `--force` reasoning from the fetcher in your own build.** The
  fetcher passes `pnpm install --force` deliberately, to pull dependencies for
  platforms other than the builder's (`fetch-pnpm-deps/default.nix:141-144`).
  The offline install in the build must not.
- **`__structuredAttrs` matters for list-valued attributes.** `pnpmWorkspaces`,
  `pnpmInstallFlags` and friends are read with `concatTo`, which works either
  way, but nixpkgs' own workspace test runs both variants explicitly
  (`pkgs/test/pnpm/pnpm-workspaces/default.nix`) because they have historically
  diverged. Test both if you ship a library.
- **Yarn is a fourth, separate story.** `fetchYarnDeps` +
  `yarnConfigHook`/`yarnBuildHook`/`yarnInstallHook` for v1
  (`all-packages.nix:471-478`), and `yarn-berry_X.fetchYarnBerryDeps` +
  `yarnBerryConfigHook` for v3/v4. None of the pnpm or npm knobs above transfer.
