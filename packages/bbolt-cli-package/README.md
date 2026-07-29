# bbolt-cli-package

Package **one** CLI out of a larger Go repository with `buildGoModule`, instead
of building every command the upstream module ships.

## Problem

Many Go projects are primarily libraries but also ship one or more commands
under `cmd/`. `etcd-io/bbolt` is the embedded BoltDB key/value store used by
countless Go services, and it happens to include a handy `bbolt` CLI for
inspecting and surgically editing those `.db` files on disk.

If you point `buildGoModule` at such a repo with no further hints, it will try
to build **all** main packages it finds — pulling in commands you do not want,
extra build time, and sometimes extra dependencies. You wanted one tool.

## Key insight / trap

Two lines do the work:

```nix
subPackages = [ "cmd/bbolt" ];   # build only this one command
ldflags     = [ "-s" "-w" ];     # strip symbol table + DWARF debug info
```

- **`subPackages`** is the important one. It restricts the build to the given
  import paths (relative to the module root, i.e. the directory with `go.mod`).
  With it, `buildGoModule` compiles and installs exactly `cmd/bbolt` and nothing
  else. Without it, every `package main` in the tree becomes an output binary.
- **`ldflags = [ "-s" "-w" ]`** is the standard Go binary-slimming pair: `-s`
  drops the symbol table, `-w` drops DWARF debug info. Useful for an ops tool
  you just want to drop on a box.
- Set `mainProgram` in `meta` so `lib.getExe` / `nix run` resolve to `bbolt`
  even though `pname` is `bbolt-cli`.

Trap when adapting to another repo: `vendorHash` must match the vendored
dependency set. Start with `lib.fakeHash`, build once, and paste the hash Nix
reports. Same for the `src` `hash`.

## Usage

```nix
# In an overlay or flake:
final: prev: {
  bbolt-cli = prev.callPackage ./packages/bbolt-cli-package { };
}
```

or directly:

```nix
pkgs.callPackage ./packages/bbolt-cli-package { }
```

Then `bbolt` is on `PATH` (add the package to `environment.systemPackages`,
`home.packages`, or a `nix shell`).

## Adapting to a different tool

To extract a different command from a different repo, change four things:

1. `src` (`owner` / `repo` / `rev` / `hash`),
2. `vendorHash`,
3. `subPackages` to the `cmd/<name>` path you actually want,
4. `mainProgram` / `meta` to match.

Everything else — the `subPackages` + `ldflags` pattern — carries over
unchanged.
