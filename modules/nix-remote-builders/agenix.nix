{
  config,
  lib,
  ...
}:
let
  cfg = config.nix.remoteBuilders;
  a = cfg.agenix;

  mkSecret =
    name:
    {
      rekeyFile = a.secretsDir + "/${name}${a.fileSuffix}";
      inherit (a) owner mode;
    }
    // lib.optionalAttrs (a.generatorScript != null) { generator.script = a.generatorScript; }
    // a.extraSecretConfig;
in
{
  config = lib.mkIf (a.enable && cfg.keyNames != [ ]) {
    assertions = [
      {
        assertion = a.secretsDir != null;
        message = ''
          nix.remoteBuilders.agenix.enable is on but secretsDir is null, so
          there is nowhere to read the encrypted builder keys from.
        '';
      }
    ];

    age.secrets = lib.genAttrs cfg.keyNames mkSecret;
  };
}
