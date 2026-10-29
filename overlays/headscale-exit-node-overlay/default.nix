final: prev:
let
  version = "0.30.0-dev";
  rev = "eeaac680bef26585c8cc1569f949e26d0d6aba80";
in
{
  headscale = prev.buildGo127Module {
    pname = "headscale";
    inherit version;

    src = final.fetchFromGitHub {
      owner = "juanfont";
      repo = "headscale";
      inherit rev;
      hash = "sha256-fLIXZKFgrGqc/rzG0WF3udNmiXH9zzvIW16h+6ry3+E=";
    };

    postPatch = ''
      substituteInPlace hscontrol/types/version.go \
        --replace-fail 'Version:   "dev"' 'Version: "${version}"' \
        --replace-fail 'Commit:    "unknown"' 'Commit: "${rev}"'
    '';

    vendorHash = "sha256-IfMJsCNx1tuCu+jkrRaN9s7TzKePwOm0Dxt3jup2ysM=";

    subPackages = [ "cmd/headscale" ];

    nativeBuildInputs = [ final.installShellFiles ];

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
