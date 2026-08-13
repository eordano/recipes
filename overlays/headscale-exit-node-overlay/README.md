# headscale-exit-node-overlay

A nixpkgs overlay that builds [Headscale](https://github.com/juanfont/headscale)
from a pinned upstream commit, to get the exit-node packet-filter fix before it
ships in a tagged release.

## The problem

Headscale generates a packet filter (the derived ACL) that tells nodes what
traffic to forward. For an **exit node** to work, that filter has to include the
"catch-all internet" routes -- `0.0.0.0/0` and `::/0`. Some released Headscale
versions **strip those CIDRs out** of the generated filter. The result is a
quiet failure: clients happily select the exit node, the route shows up, but no
traffic actually egresses through it. Nothing errors; packets just go nowhere.

The fix for this landed on Headscale's `main` branch before it was cut into a
release tag. This overlay pins `pkgs.headscale` to a commit that contains it, so
you can run working exit nodes on your own control server today instead of
waiting for the next tag.

## The trap (why this is a recipe and not a one-liner)

Building a Go program from a moving commit means **four values have to be bumped
together every time**. Change one without the others and you either build the
wrong thing or fail the build:

| Value | What it is | What goes wrong if it's stale |
|---|---|---|
| `rev` | the commit you want | you don't get the fix |
| `hash` | `fetchFromGitHub` source hash | Nix fetches the *old* source (hash mismatch or wrong tree) |
| `vendorHash` | Go module vendor hash | vendor step fails whenever `go.mod`/`go.sum` moved |
| `version` | string substituted into `version.go` | `headscale version` reports a stale/`dev` value |

The `postPatch` uses `--replace-fail` (not `--replace`) on purpose: if upstream
ever changes the `Version:`/`Commit:` lines in `version.go`, the build **fails
loudly** instead of silently producing a binary with the wrong version string.
That failure is your signal to re-check the whole pin.

## Usage

Import the overlay into your nixpkgs configuration:

```nix
nixpkgs.overlays = [ (import ./overlays/headscale-exit-node-overlay) ];
```

Everything that consumes `pkgs.headscale` -- including `services.headscale` -- then
uses this build. No other wiring is required.

## Bumping the pin

1. Pick a new `rev` on upstream `main` (or the branch carrying the fix).
2. Update `hash` (get it from `nix-prefetch-github juanfont headscale --rev <rev>`
   or let the build tell you the correct hash on first failure).
3. Set `vendorHash` to `lib.fakeHash`, build, and copy the correct hash from the
   error -- but only if `go.mod`/`go.sum` changed between commits.
4. Update `version` if upstream's dev version bumped, and confirm the
   `--replace-fail` lines still match `hscontrol/types/version.go`.

## When to delete this

This overlay is a stopgap. Once a **released** Headscale version includes the
exit-node filter fix, remove the overlay entirely and go back to the packaged
`pkgs.headscale`. Carrying a source pin forever means you also carry the burden
of manually tracking every security fix upstream.

## Notes

- Only `cmd/headscale` is built (`subPackages`); the other command packages
  aren't needed for a control server.
- The test suite needs a real PostgreSQL and a syscall-redirect shim, which is
  why `postgresql` and `libredirect.hook` are in `nativeCheckInputs`. Tests run
  with `-short`.
- Shell completions are installed for bash/fish/zsh when the build host can
  execute the target binary (skipped on cross-compiles).
