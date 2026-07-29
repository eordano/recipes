# Gate systemd consumers on actual service readiness

`After=` orders unit startup; it does not prove that a dependency is ready.
systemd considers a `Type=simple` service started as soon as its process forks,
often before migrations, warmup, socket binding, or an HTTP health check finish.

This module turns a command, TCP connection, or HTTP request into a oneshot
`<name>-ready.service` that dependent units can safely require.

## Use

```nix
{
  imports = [ inputs.recipes.nixosModules.service-readiness-gate ];

  modules.services.readiness-gates = {
    garage = {
      http = "http://127.0.0.1:3903/health";
      after = [ "garage.service" ];
      requiredBy = [ "garage-init.service" ];
      timeoutSeconds = 120;
    };
  };
}
```

Each gate must set exactly one probe:

- `command`: a shell command that exits zero when ready;
- `tcp`: a `{ host, port }` connection check;
- `http`: a URL that must return a successful HTTP status.

Setting zero or several probe types fails evaluation with the gate's name.

## Contract

For a gate named `foo`, the module:

- creates `foo-ready.service` as a `Type=oneshot` unit;
- orders and requires its own dependencies through `after` and `requires`;
- adds `Requires=foo-ready.service` and `After=foo-ready.service` to every
  unit named by `requiredBy`;
- keeps the successful gate active with `RemainAfterExit=true`.

`requiredBy` accepts names with or without further unit configuration; the
module removes a `.service` suffix when extending `systemd.services`.

Several gates may guard the same consumer. Their dependency lists accumulate:
the implementation uses `lib.mkMerge`, not recursive-update-by-accident.

## Failure behavior

When `timeoutSeconds` expires, the gate fails and its required consumers remain
stopped. This is intentional: one failed readiness unit is more diagnosable than
a consumer restarting forever against a dependency that never became usable.

Probe attempts repeat every `intervalSeconds`; the default is one second.

## Traps this avoids

### `After=` is not a health check

Ordering against the raw service only waits for systemd's start transition. It
does not wait for the daemon to accept connections.

### Exactly one probe keeps failures legible

Implicit precedence between `command`, `tcp`, and `http` would make a typo look
like a successful configuration. Ambiguous gates fail during evaluation.

### TCP probing needs Bash

The TCP probe uses Bash's `/dev/tcp` support under a short timeout. The generated
waiter carries Bash, curl, and coreutils explicitly and accepts `extraPackages`
for custom command probes.

## Testing

[`test.nix`](./test.nix) is a NixOS VM test. Run it directly:

```console
$ nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
