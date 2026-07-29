# Optional companion to ./default.nix — import BOTH, plus the agenix (or
# agenix-rekey) module itself, if you want the builder keys declared as
# secrets and the IdentityFile resolved from `config.age.secrets.<name>.path`.
#
# This lives in its own file because a module cannot conditionally define an
# option path that may not exist. `mkIf false { age.secrets = …; }` still
# registers `age` as a defined path — the module system pushes properties down
# into each attribute before it checks definitions against declarations — so a
# single-file version fails with "The option `age' does not exist" on every
# host that has no agenix module, even with the feature switched off.
#
# Using a different secret manager? Do not import this file. Read
# `config.nix.remoteBuilders.keyNames` (read-only, de-duplicated, and empty on
# hosts that route to no builder) and declare the secrets yourself, then point
# each builder's `identityFile` at the resulting path.

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

    # genAttrs, not a map into a list: several builders legitimately share one
    # keypair, and `keyNames` is already de-duplicated for that reason.
    age.secrets = lib.genAttrs cfg.keyNames mkSecret;
  };
}
