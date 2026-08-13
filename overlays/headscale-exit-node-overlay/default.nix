# Overlay: build Headscale from an unreleased upstream commit.
#
# Why: some released Headscale versions strip the 0.0.0.0/0 and ::/0 internet
# CIDRs out of the packet filter they generate for exit nodes, which silently
# breaks exit-node packet forwarding (clients route through the node but no
# traffic egresses). The fix landed on `main` before it landed in a tag, so
# this overlay pins Headscale to a specific `rev` that contains it.
#
# THE TRAP -- four values must move together on every bump, or the build is
# either wrong or broken:
#   1. rev        -- the commit you want (contains the filter fix)
#   2. hash       -- fetchFromGitHub source hash for that rev
#   3. vendorHash -- Go module vendor hash (changes whenever go.mod/go.sum move)
#   4. version    -- substituted into version.go so `headscale version` is honest
# If you bump `rev` but not `hash`, Nix fetches the old source. If you bump the
# source but not `vendorHash`, the vendor step fails. If you forget the
# version.go substitution, the binary reports a stale/"dev" version.
#
# Usage: add to your nixpkgs overlays, e.g.
#   nixpkgs.overlays = [ (import ./overlays/headscale-exit-node-overlay) ];
# then `services.headscale` (or any `pkgs.headscale` consumer) uses this build.
#
# When upstream cuts a release that includes the fix, DELETE this overlay and
# go back to the packaged `pkgs.headscale`.

final: prev:
let
  # Pin these together. See "THE TRAP" above.
  version = "0.29.0-dev"; # substituted into the binary's reported version
  rev = "f905d58292866df651d0646b174cdfff4c4545c0"; # commit carrying the exit-node filter fix
in
{
  headscale = prev.buildGoModule {
    pname = "headscale";
    inherit version;

    src = final.fetchFromGitHub {
      owner = "juanfont";
      repo = "headscale";
      inherit rev;
      # Bump this whenever you bump `rev`.
      hash = "sha256-yPSTyRaMfENYtgZjbj4KC43/niA8sEsYo5TkVnXGSSg=";
    };

    # Make the binary report the pinned version/commit instead of "dev"/"unknown".
    # --replace-fail errors out (rather than silently no-op'ing) if upstream
    # changes these lines, which is your early warning that the pin needs review.
    postPatch = ''
      substituteInPlace hscontrol/types/version.go \
        --replace-fail 'Version:   "dev"' 'Version: "${version}"' \
        --replace-fail 'Commit:    "unknown"' 'Commit: "${rev}"'
    '';

    # Bump this whenever the vendored Go dependencies change (go.mod/go.sum).
    vendorHash = "sha256-Y9f0Q2Kw07eB8bURLT0jce+YoSs2WoowEX7t8tkNDvw=";

    # Only the CLI/server binary is needed; skip building the other cmd packages.
    subPackages = [ "cmd/headscale" ];

    nativeBuildInputs = [ final.installShellFiles ];

    # Headscale's test suite spins up a real PostgreSQL and redirects some
    # syscalls; provide those so `-short` checks can run in the sandbox.
    nativeCheckInputs = [
      final.libredirect.hook
      final.postgresql
    ];

    checkFlags = [ "-short" ];

    postInstall = final.lib.optionalString (final.stdenv.buildPlatform.canExecute final.stdenv.hostPlatform) ''
      installShellCompletion --cmd headscale \
        --bash <($out/bin/headscale completion bash) \
        --fish <($out/bin/headscale completion fish) \
        --zsh <($out/bin/headscale completion zsh)
    '';

    meta = {
      homepage = "https://github.com/juanfont/headscale";
      description = "Open source, self-hosted implementation of the Tailscale control server";
      license = final.lib.licenses.bsd3;
      mainProgram = "headscale";
    };
  };
}
