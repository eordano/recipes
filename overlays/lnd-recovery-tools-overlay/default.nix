# lnd-recovery-tools-overlay
#
# A self-contained Nixpkgs overlay that packages two Lightning/Bitcoin operator
# CLIs that are (as of writing) absent from nixpkgs:
#
#   * chantools  — Lightning Labs' last-resort toolkit for rescuing funds from
#                  LND channels (SCB recovery, force-close sweeps, key
#                  derivation, on-chain address sweeping).
#   * bbolt-cli  — the etcd-io/bbolt CLI, for inspecting and surgically editing
#                  BoltDB / bbolt database files — the embedded k/v store LND
#                  keeps its `channel.db` in, and that many Go services use.
#
# Both are plain `buildGoModule` derivations wired into an overlay via
# `callPackage`, so `pkgs.chantools` / `pkgs.bbolt-cli` become available fleet-
# wide once the overlay is registered.
#
# Usage — register the overlay:
#
#   nixpkgs.overlays = [ (import ./lnd-recovery-tools-overlay) ];
#
# or on a bare nixpkgs import:
#
#   import <nixpkgs> { overlays = [ (import ./lnd-recovery-tools-overlay) ]; };
#
# then reference `pkgs.chantools` and `pkgs.bbolt-cli` in `environment.systemPackages`,
# a `nix shell`, or a devShell.
#
# --- Bumping versions -------------------------------------------------------
# When you change `version`, both the source `hash` AND the `vendorHash` will
# change. The reliable loop: set the new version, set both hashes to
# `lib.fakeHash`, build once, and copy the two "got:" hashes the error prints.
# `vendorHash` covers the whole vendored Go module tree — a stale value fails
# the build with a hash mismatch, it does not silently use old deps.

final: prev:

let
  # chantools — Lightning channel rescue toolkit (Lightning Labs).
  #
  # No `-X` version stamping here, and that is deliberate: for this release
  # `chantools --version` is fed by `version` and `Commit`, both declared in a
  # `const` block in `cmd/chantools/root.go`. The Go linker's `-X` can only
  # patch string *variables*, never constants, so any `-X …Version=…` /
  # `-X …Commit=…` pair is silently discarded — including upstream's own
  # `-X main.Commit=…` in their Makefile. The binary already reports the right
  # version because the constant carries it; `commit` just stays empty.
  #
  # (An earlier revision of this overlay stamped
  # `github.com/lightningnetwork/chantools.{Version,Commit}`, which was wrong
  # twice over: the module path is `github.com/lightninglabs/chantools` — see
  # `go.mod` — and the symbols live in package `main` under `cmd/chantools`,
  # not at the module root.)
  chantools = prev.callPackage (
    {
      lib,
      buildGoModule,
      fetchFromGitHub,
    }:
    buildGoModule rec {
      pname = "chantools";
      version = "0.14.2";

      src = fetchFromGitHub {
        owner = "lightninglabs";
        repo = "chantools";
        rev = "v${version}";
        hash = "sha256-pHcTBoipN1mYdGPswgAUVs/A3k1HKD5LXmCxwduStOw=";
      };

      vendorHash = "sha256-+jOrR8jhNdMvICwwLPAuYTGjlkXh7y4tZceioi9EJQI=";

      # The module root holds no Go files at all — `main` lives in
      # `cmd/chantools`. `subPackages = [ "." ]` builds cleanly and installs
      # NOTHING, leaving an empty derivation and a `mainProgram` that does not
      # exist; the failure only shows up when you try to run the tool.
      subPackages = [ "cmd/chantools" ];

      ldflags = [
        "-s"
        "-w"
      ];

      # One upstream unit test compares against a stale golden dump and fails
      # in a clean checkout. The rest of `cmd/chantools`' tests run and pass.
      checkFlags = [ "-skip=^TestCompactDBAndDumpChannels$" ];

      meta = {
        description = "Tools for rescuing funds from Lightning Network channels";
        homepage = "https://github.com/lightninglabs/chantools";
        license = lib.licenses.mit;
        mainProgram = "chantools";
      };
    }
  ) { };

  # bbolt-cli — the `bbolt` CLI from etcd-io/bbolt.
  # The upstream repo is the bbolt library; the CLI lives in `cmd/bbolt`, so
  # `subPackages = [ "cmd/bbolt" ]` builds just that one binary (named `bbolt`).
  bbolt-cli = prev.callPackage (
    {
      lib,
      buildGoModule,
      fetchFromGitHub,
    }:
    buildGoModule rec {
      pname = "bbolt-cli";
      version = "1.4.3";

      src = fetchFromGitHub {
        owner = "etcd-io";
        repo = "bbolt";
        rev = "v${version}";
        hash = "sha256-awBkr2ObRxPQkMlfVFZxEbQ9JQJsFrJvSBHtqP4Hb3I=";
      };

      vendorHash = "sha256-TzVmAMrNrNkFE9jQ+SILJXvbhBK1WenNPqA0FfuDU+M=";

      subPackages = [ "cmd/bbolt" ];

      ldflags = [
        "-s"
        "-w"
      ];

      meta = {
        description = "BoltDB CLI tool for inspecting and manipulating bbolt databases";
        homepage = "https://github.com/etcd-io/bbolt";
        license = lib.licenses.mit;
        mainProgram = "bbolt";
      };
    }
  ) { };
in
{
  inherit chantools bbolt-cli;
}
