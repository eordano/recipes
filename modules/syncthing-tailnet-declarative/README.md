# syncthing-tailnet-declarative

A NixOS module that runs [Syncthing](https://syncthing.net/) as a **discovery-free
mesh pinned to a tailnet** (Tailscale / any WireGuard VPN), and sets the Web GUI
password **declaratively** — without the password ever entering the Nix store.

## The problem

Syncthing's defaults assume the open internet: it announces itself to global
discovery servers, punches NAT, and falls back to public relays so any two devices
can find each other from anywhere. If all your devices already share a private
tailnet, you don't want any of that — it's attack surface and it leaks metadata to
third parties.

There's also a smaller, sharper annoyance: **there is no NixOS option for the GUI
password.** Syncthing stores it bcrypt-hashed in `config.xml`, generated at runtime.
You can't declare the hash sensibly, and you certainly don't want the plaintext
sitting world-readable in `/nix/store`.

## What this module does

**1. Closes the mesh.** Global announce, relays and NAT traversal are all turned
off; local (LAN) announce stays on. Every peer is pinned to a fixed tailnet address
(`tcp://<tailnet-ip>:22000`). Discovery never leaves the tailnet.

**2. Orders the daemon after the tailnet.** Those pinned peer addresses don't exist
until the VPN is up, so `syncthing` and `syncthing-init` are ordered `after` (and
`wants`) the tailnet unit — `tailscaled.service` by default, configurable for
`wg-quick`, etc.

**3. Sets the GUI password declaratively.** A `oneshot` service reads the plaintext
password from a secret file (agenix, sops-nix, …) and PUTs it through Syncthing's own
REST API (`/rest/config/gui`). Syncthing hashes it on receipt. The password lives
only in your secrets manager and in RAM at activation time — never in the store.

### The trap this encodes

The REST API needs an **API key**, and Syncthing only generates that key on its
**own first run** — it isn't there when the module is activated. So the oneshot
**polls `config.xml` for up to 60 seconds** (via `xmllint --xpath`) until the key
appears, and only then calls the API. Skip the poll and the password step races
Syncthing's first boot and fails intermittently. The `curl` calls additionally
`--retry` in case the HTTP listener isn't accepting yet.

## Usage

```nix
{
  imports = [ ./syncthing-tailnet-declarative ];

  services.syncthingTailnet = {
    enable = true;

    # Bind the GUI to loopback (or a tailnet IP). Never expose it publicly —
    # there's a brief window at first boot before the password is set.
    guiAddress = "127.0.0.1";
    guiPort = 8384;

    # Plaintext password file from your secrets manager. Must be readable by
    # the syncthing user. Omit to leave the GUI open (loopback only!).
    guiPasswordFile = config.age.secrets.syncthing-gui-password.path;

    # Whatever brings the tailnet up. Default is tailscaled.service.
    # orderAfterUnits = [ "wg-quick-wg0.service" ];

    # Peers, pinned to their tailnet addresses.
    devices = {
      laptop = {
        id = "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH";
        addresses = [ "tcp://100.100.100.10:22000" ];
      };
      phone = {
        id = "IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP";
        addresses = [ "tcp://100.100.100.20:22000" ];
      };
    };

    folders = {
      "shared" = {
        path = "/var/lib/syncthing/Shared";
        devices = [ "laptop" "phone" ];
      };
    };
  };
}
```

Get a device's ID with `syncthing --device-id` on that device (or from its GUI).

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Turn the module on. |
| `user` / `group` | `"syncthing"` | Identity the daemon runs as. |
| `uid` | `null` | Pin a fixed UID (handy for shared/persisted data dirs across a fleet); overrides the upstream default of `ids.uids.syncthing`. Null keeps that default. |
| `dataDir` | `/var/lib/syncthing` | Synced data / default folder location. |
| `configDir` | `${dataDir}/.config/syncthing` | Holds `config.xml`, keys, DB. |
| `guiAddress` | `127.0.0.1` | GUI/REST bind address. Keep it private. |
| `guiPort` | `8384` | GUI/REST port (not opened in the firewall). |
| `guiUser` | `"syncthing"` | Username set alongside the password. |
| `guiPasswordFile` | `null` | Path to a plaintext-password secret file. Null = no password. |
| `listenPort` | `22000` | Peer sync TCP/UDP port. |
| `orderAfterUnits` | `[ "tailscaled.service" ]` | Units that must be up first. |
| `openFirewall` | `true` | Open the sync port + local-discovery UDP 21027 (never the GUI port). |
| `devices` | `{}` | Peers with pinned tailnet addresses. |
| `folders` | `{}` | Folders to sync. |

## Caveats

- **Keep the GUI on loopback or a tailnet address.** Between Syncthing's first boot
  and the password oneshot completing, the GUI is briefly unauthenticated. The module
  deliberately does not open the GUI port in the firewall.
- **Local announce stays on.** If you want a *strictly* addressed mesh with zero
  broadcast, set `localAnnounceEnabled = false` too (it's left on here so devices on
  the same LAN still connect fast).
- **`overrideDevices` / `overrideFolders` are `true`.** Nix is the source of truth;
  devices and folders you add through the GUI are reverted on the next rebuild.
- Requires a secrets manager that can drop a plaintext password file readable by the
  syncthing user. Any of agenix, sops-nix, or a manually-provisioned file works —
  the module only cares about the path.
