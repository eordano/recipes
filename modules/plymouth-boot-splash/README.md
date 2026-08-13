# plymouth-boot-splash

A small NixOS module with two **independent, opt-in** flags for a desktop
machine:

- `modules.bootConfig.enable` -- use **systemd-boot** on EFI with sensible
  desktop defaults.
- `modules.plymouth.enable` -- a graphical **Plymouth** boot splash that hides
  boot log spam behind `quiet`.

They are deliberately separate: you can want a clean bootloader without a
splash, or a splash on a machine whose bootloader you configure elsewhere.

## Why this exists

Turning on a boot splash is a two-line change that quietly buries two sharp
edges. This module bakes both mitigations in so you do not have to rediscover
them the hard way.

### Trap 1 -- the systemd-boot cmdline editor is a local-root bypass

`systemd-boot` ships a boot-time editor: press `e` at the menu and you can
append arbitrary kernel parameters. `init=/bin/sh` (or `rd.break`,
`systemd.unit=rescue.target`, ...) drops you straight into a **root shell with
no password**, bypassing your login, your PAM policy, and often your disk
layout entirely.

That is sometimes convenient on a desktop you physically own and control -- but
it is a full local-root escalation for anyone who can touch the keyboard. So
the editor is a **separate option defaulting to `false`**. Enable it only on a
physically trusted desktop:

```nix
modules.bootConfig.enable = true;
modules.bootConfig.editor = true;   # only if the box never leaves your sight
```

Leave it off for laptops, kiosks, lab machines, or anything an untrusted
person could reach.

### Trap 2 -- `quiet` + a splash makes early boot go dark

A splash works by hiding kernel and systemd output behind `quiet`. The problem:
early boot is exactly when things break in ways you *need* to see -- a missing
initrd module, a failed LUKS unlock, a root device that never appears. Under a
naive `quiet` splash those failures present as a **frozen logo with no
message**.

The fix is to keep the **initrd** stage verbose while only silencing the later,
less interesting log noise:

```nix
boot.initrd.verbose = lib.mkDefault true;   # early-boot failures stay visible
```

This module sets that for you (as a `mkDefault`, so a host can still override).

## Usage

Import the module and flip the flags you want:

```nix
{
  imports = [ ./modules/plymouth-boot-splash ];

  modules.bootConfig.enable = true;
  # modules.bootConfig.editor = true;   # physically-trusted desktop only

  modules.plymouth.enable = true;
  # modules.plymouth.theme = "spin";    # any theme your themePackages provide
}
```

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `modules.bootConfig.enable` | `false` | Enable systemd-boot EFI defaults. |
| `modules.bootConfig.editor` | `false` | Boot-time cmdline editor. **Local-root bypass -- trusted desktops only.** |
| `modules.bootConfig.canTouchEfiVariables` | `true` | Allow writing EFI NVRAM variables. |
| `modules.plymouth.enable` | `false` | Enable the Plymouth splash. |
| `modules.plymouth.theme` | `"square_hud"` | Theme name; must be provided by `themePackages`. |
| `modules.plymouth.themePackages` | adi1090x pack (subset) | Packages that install the theme. Override to shrink the closure or use your own theme. |

## Caveats

- **Theme closure size.** The default `themePackages` pulls a large third-party
  theme pack; the `selected_themes` override keeps only a handful. Trim it
  further, or replace it with any package that installs your chosen theme.
- **A splash is not encryption UX.** If you use LUKS, Plymouth renders the
  passphrase prompt, but the splash itself provides no security -- it only
  changes what you see. The security-relevant knob here is the editor flag.
- **EFI-only.** `modules.bootConfig` assumes systemd-boot, i.e. a UEFI system.
  On BIOS/GRUB machines, use only the `modules.plymouth` half.
