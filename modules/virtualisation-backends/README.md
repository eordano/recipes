# virtualisation-backends

One NixOS module that gates four VM/container back-ends behind a single boolean
each:

- **VirtualBox host** — run VirtualBox VMs on this machine
- **VirtualBox guest** — guest additions, for when *this* machine is itself a
  VirtualBox VM
- **virt-manager** — QEMU/KVM via `libvirtd`, driven by virt-manager
- **Waydroid** — an Android container

The wiring is trivial. The value of this recipe is three traps that each cost a
debugging session to find, all preserved in the code with comments.

## The traps

### 1. `config` must be `mkMerge`, never a `//`-chain of `mkIf` blocks

It is tempting to write:

```nix
config =
  (mkIf cfg.a { ... }) //
  (mkIf cfg.b { ... }) //   # WRONG
  (mkIf cfg.c { ... });
```

`//` is plain attribute-set update: it keeps only the **last** operand's
attributes and silently discards every earlier block. The result type-checks,
evaluates, and builds — it is just missing most of your config, with no error to
point at it. `//` is only safe between plain attrsets that carry no
module-system properties (no `mkIf` / `mkMerge` / `mkDefault` inside).

Use `mkMerge`, the module-system-aware combinator that actually merges the
branches:

```nix
config = mkMerge [
  (mkIf cfg.a { ... })
  (mkIf cfg.b { ... })
  (mkIf cfg.c { ... })
];
```

This is the same bug that has silently neutered whole hardening modules
elsewhere — worth internalizing once.

### 2. VirtualBox host needs `addNetworkInterface = false`

With `enableKvm = true`, the VirtualBox host backend is NAT-only. The host-only
`vboxnet0` interface that `addNetworkInterface = true` (the default) would create
trips a NixOS assertion and refuses to build. Keep it `false`. If you truly need
host-only networking you have to give up the KVM backend.

### 3. Drop ceph/glusterfs from QEMU

`pkgs.qemu_full` pulls in ceph and glusterfs storage backends by default. On a
desktop VM host they are dead weight — and on current nixpkgs unstable (gcc15)
ceph **fails to compile**, which blocks the machine's entire system closure from
building. Override them off:

```nix
package = pkgs.qemu_full.override {
  cephSupport = false;
  glusterfsSupport = false;
};
```

### Bonus gotcha

Recent nixpkgs removed the `x11` sub-option from
`virtualisation.virtualbox.guest`. Don't set it; it no longer exists. Its
neighbour `dragAndDrop` *does* still exist (and defaults to `true`), but it was
renamed from the older lowercase `draganddrop`, so an old config spelling it
that way rides a rename shim rather than the real option. The module here sets
neither and takes the guest defaults.

## Usage

Import the module and flip the booleans you want. Point `user` at your login
account — it is added to the relevant groups (`vboxusers`, `libvirtd`) and runs
the QEMU processes.

```nix
{
  imports = [ ./modules/virtualisation-backends ];

  modules.virtualisation = {
    virtmanager = true;   # QEMU/KVM + virt-manager
    virtualbox  = true;   # VirtualBox host
    user        = "alice";
    # group    = "users"; # primary group of `user`; default is fine on NixOS
    # virtualbox-guest = true;   # only inside a VirtualBox VM
    # waydroid         = true;
  };
}
```

## Options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `modules.virtualisation.virtualbox` | bool | `false` | VirtualBox host |
| `modules.virtualisation.virtualbox-guest` | bool | `false` | VirtualBox guest additions |
| `modules.virtualisation.virtmanager` | bool | `false` | QEMU/KVM via virt-manager |
| `modules.virtualisation.waydroid` | bool | `false` | Waydroid Android container |
| `modules.virtualisation.user` | str | `"user"` | User granted access to the enabled back-ends |
| `modules.virtualisation.group` | str | `"users"` | Primary group of `user`, used as the QEMU process group |

## Caveats

- `swtpm.enable = true` is on so Windows 11 guests get a virtual TPM; drop it if
  you don't need it.
- `runAsRoot = true` plus a `user`/`group` in `verbatimConfig` runs the libvirt
  helper as root but the QEMU processes as your user. Adjust to taste if your
  threat model wants the tighter, rootless setup. Keep `verbatimConfig` to just
  those two lines: adding `namespaces = []` disables libvirt's per-VM
  mount-namespace isolation machine-wide and hands a guest escape the host's
  full `/dev`.
- `virtmanager` also turns on `spiceUSBRedirection`, so USB devices can be
  passed through to guests from virt-manager.
- Enabling `virtmanager` also enables `programs.dconf` (virt-manager stores its
  settings there).
