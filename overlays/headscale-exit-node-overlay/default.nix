final: prev:
let
  version = "0.29.0-dev";
  rev = "f905d58292866df651d0646b174cdfff4c4545c0";
in
{
  headscale = prev.buildGoModule {
    pname = "headscale";
    inherit version;

    src = final.fetchFromGitHub {
      owner = "juanfont";
      repo = "headscale";
      inherit rev;
      hash = "sha256-yPSTyRaMfENYtgZjbj4KC43/niA8sEsYo5TkVnXGSSg=";
    };

    postPatch = ''
      substituteInPlace hscontrol/types/version.go \
        --replace-fail 'Version:   "dev"' 'Version: "${version}"' \
        --replace-fail 'Commit:    "unknown"' 'Commit: "${rev}"'
    '';

    vendorHash = "sha256-Y9f0Q2Kw07eB8bURLT0jce+YoSs2WoowEX7t8tkNDvw=";

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
