# keycloak-keywind-theme-overlay

Package the third-party Tailwind Keycloak theme **[Keywind](https://github.com/lukin/keywind)** from source with `buildNpmPackage`, and expose it through an overlay so `services.keycloak.themes` can consume it.

## Problem

Keycloak's login pages are ugly by default, and Keywind is a nice Tailwind restyle — but it ships as source, not as a Nix package. You have to build the theme jar yourself, and NixOS's `services.keycloak.themes.<name>` wants something very specific in return: a directory that *is* one theme flavour, not the jar and not the jar's directory tree.

## The insight / trap

Keywind builds in two npm steps:

1. `npm run build` — compiles the Tailwind/FreeMarker assets.
2. `npm run build:jar` — packs them into `out/keywind.jar`, a standard Keycloak theme jar.

A Keycloak theme jar has the layout:

```
theme/<themeName>/<themeType>/...   e.g.  theme/amora/login/...
```

`services.keycloak.themes.<name> = pkg;` expects `pkg` to point at the **innermost** directory — the one that directly contains `theme.properties`, `login/` (or the flavour templates), `resources/`, `messages/`, etc. It does **not** want the jar, and it does **not** want the `theme/` wrapper or the intermediate `<themeName>/` directory.

So after `build:jar` you must unzip the jar and copy **only** `theme/amora/login` to `$out`. That `login` subdirectory is the entire output Keycloak actually consumes. Ship the wrapper instead and Keycloak silently fails to find the theme — no error, the theme just never appears.

(`amora` is the internal name Keywind's build bakes into the jar. It is *not* the name you pick in Keycloak — that comes from the attribute name you inherit into `services.keycloak.themes`.)

## Usage

Wire the overlay into your nixpkgs and inherit the theme into Keycloak:

```nix
{ pkgs, ... }:
{
  nixpkgs.overlays = [ (import ./default.nix).overlay ];

  services.keycloak = {
    enable = true;
    # ... hostname, database, etc. ...
    themes = {
      inherit (pkgs.keycloak-themes) keywind;
    };
  };
}
```

Then, in a realm's *Login theme* dropdown, select **keywind**.

Or build the bare package without the overlay:

```nix
pkgs.callPackage (import ./default.nix).default { }
```

## Options

The package function takes two knobs (both with sensible defaults) so you can retarget a fork without editing the logic:

| Option | Default | Meaning |
| --- | --- | --- |
| `themeType` | `"login"` | Which Keycloak theme flavour to keep out of the jar. |
| `themeName` | `"amora"` | The name Keywind's build packs the theme under inside the jar (`theme/<themeName>/`). An implementation detail of the source, not the Keycloak-facing name. |

## Caveats

- **Pin and audit the source.** Bump `rev`/`hash`/`npmDepsHash` to a commit you have reviewed. To find the correct hashes, build once with a placeholder hash and copy the `got:` value Nix prints.
- **`npmDepsHash` must match the locked `package-lock.json`** at the pinned `rev`. If you change the revision you must refresh this hash too.
- Keywind currently provides only a **login** theme. If you point `themeType` at a flavour the jar doesn't contain, the `cp -a` in `installPhase` will fail the build — which is the safe outcome.
