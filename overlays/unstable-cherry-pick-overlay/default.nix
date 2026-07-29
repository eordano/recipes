# unstable-cherry-pick-overlay
#
# Cherry-pick a handful of fast-moving packages from nixpkgs-unstable onto an
# otherwise-stable nixpkgs, via a plain overlay. The rest of your system keeps
# tracking the stable channel; only the packages named here jump ahead.
#
# The whole reason this file is more than a one-line `inherit (unstable) ...`
# is that fast-moving packages regularly need small build fixes to succeed in
# the Nix sandbox. Two shapes recur, so read the traps before copy-pasting:
#
#   1. Sandbox-incompatible tests. The build sandbox has no network, no
#      /dev/ptmx, and tight fd limits. Tests that assume any of those fail in
#      the sandbox even though the package is fine — disable them (per-test with
#      `disabledTests`, or wholesale with `doCheck = false`) rather than
#      carrying a real regression.
#
#   2. Pinned build-backend lag. A package can pin its PEP-517 build backend to
#      a narrow version range that the nixpkgs-unstable interpreter set no
#      longer provides, so it fails to *build* (not test). Relax the pin in
#      `pyproject.toml` and supply the backend from the unstable python set.
#
# ── How to wire this up ──────────────────────────────────────────────────────
#
# In your flake, add a second nixpkgs input tracking unstable:
#
#     inputs.nixpkgs.url        = "github:NixOS/nixpkgs/nixos-25.05";
#     inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
#
# Then apply this overlay when you instantiate your stable `pkgs`, passing the
# unstable package set in. `unstable` here is a fully-instantiated package set
# (`import nixpkgs-unstable { inherit system; config = ...; }`), NOT the raw
# flake input — instantiate it for the same `system`/`config` as your base so
# the cherry-picked packages match your platform:
#
#     let
#       unstable = import inputs.nixpkgs-unstable {
#         inherit system;
#         config.allowUnfree = true;   # match your base config
#       };
#     in
#     import inputs.nixpkgs {
#       inherit system;
#       overlays = [
#         (import ./overlays/unstable-cherry-pick-overlay { inherit unstable; })
#       ];
#     };
#
# `zig` is an OPTIONAL example of pulling a package from a *third* source — an
# external flake input that publishes its own `packages.<system>.*` (here, the
# Zig toolchain's `master`). Drop the arg and the `zig = ...` line if you don't
# need it; it only illustrates that overlay inputs can come from anywhere, not
# just `unstable`. If you keep it, add the input to your flake:
#
#     inputs.zig.url = "github:mitchellh/zig-overlay";
#
{
  # Fully-instantiated nixpkgs-unstable package set (see header).
  unstable,

  # OPTIONAL external flake input exposing packages.<system>.<name>.
  # Remove this arg (and the `zig` attr below) if unused.
  zig ? null,
}:
final: prev:
{
  # ── Trap 1a: disable specific network-bound tests ──────────────────────────
  # These three tests reach out to the network / touch state the sandbox
  # forbids. Everything else in the test suite still runs. Prefer this
  # surgical form over `doCheck = false` when only a few tests are the problem.
  aider-chat = unstable.aider-chat.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or [ ]) ++ [
      "test_max_context_tokens"
      "test_cmd_read_only_with_image_file"
      "test_cmd_tokens_output"
    ];
  });

  # ── Trap 1b: disable the whole check phase ─────────────────────────────────
  # This package's test suite aborts the *build* in the sandbox: its pty tests
  # hit OpenptyFailed (no /dev/ptmx) and a hostname check fails. These are
  # sandbox incompatibilities, not regressions, so drop checks wholesale.
  ghostty = unstable.ghostty.overrideAttrs (_: {
    doCheck = false;
  });

  # ── Straight cherry-picks (no fix needed) ──────────────────────────────────
  # The common case: just take the unstable build as-is. Trim / extend this
  # list to whatever you actually want ahead of the stable channel.
  inherit (unstable)
    atuin
    neovim
    ;

  # ── Trap 2: relax a lagging pinned build backend ───────────────────────────
  # This package pins `uv_build` to a narrow range (`>=0.8.3,<0.12.0`) that the
  # unstable interpreter set no longer satisfies, so it fails to build. The fix:
  #   - drop nixpkgs' own patch that hard-pins the backend (filtered by name),
  #   - relax the upper bound in pyproject.toml,
  #   - supply the build backend + any newly-required deps from `unstable`.
  # `--replace-quiet` is used so the substitution is a no-op (not an error) if a
  # future version already relaxed the pin upstream.
  marimo = unstable.marimo.overridePythonAttrs (old: {
    patches = builtins.filter (
      p: !(p ? name && p.name == "uv-build.patch")
    ) (old.patches or [ ]);
    build-system = (old.build-system or [ ]) ++ [ unstable.python3Packages.uv-build ];
    dependencies = (old.dependencies or [ ]) ++ [ unstable.python3Packages.msgspec ];
    pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "jedi" ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace pyproject.toml \
        --replace-quiet 'uv_build>=0.8.3,<0.12.0' 'uv_build>=0.8.3'
    '';
  });
}
# ── Optional: pull from a third source (an external flake input) ─────────────
# Merged in only when `zig` is provided. Demonstrates that an overlay's inputs
# need not all come from `unstable`.
// prev.lib.optionalAttrs (zig != null) {
  zig = zig.packages.${prev.stdenv.hostPlatform.system}.master;
}
