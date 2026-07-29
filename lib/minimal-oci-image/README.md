# minimal-oci-image

Build a **super-minimal OCI/Docker image out of the Nix store** — no distro
base, no package manager, no shell, no `apk add ca-certificates` — and still
have TLS, a non-root user, a timezone and a working `$PATH`.

`pkgs.dockerTools` already gives you the hard part: the closure of a program is
the image. What it does *not* give you is the six-item checklist that turns
"the closure is in a tarball" into "the container actually runs". This wrapper
encodes that checklist, and the README below is a list of the ways each item
fails when you forget it — each one reproduced and measured on a real Docker
daemon while writing this.

## The problem

A `FROM alpine` image costs you a package manager, a shell, a libc you did not
choose, and a supply chain you do not control. The Nix alternative is one line:

```nix
pkgs.dockerTools.buildLayeredImage {
  name = "myapp";
  config.Entrypoint = [ (lib.getExe pkgs.myapp) ];
}
```

That image works — until the app makes an HTTPS request, or looks up its own
username, or writes to `/tmp`, or a `HEALTHCHECK` runs, or someone types
`docker exec -it … sh`. Each of those fails with an error that does not say
"your image is missing `/etc/ssl`", it says something else entirely.

## What upstream nixpkgs does and does not do

Everything cited below is from a nixpkgs checkout at
`pkgs/build-support/docker/default.nix` unless stated otherwise.

Upstream **does** ship the individual pieces, and this recipe uses them rather
than hand-rolling:

| Piece | Where | What it gives you |
| --- | --- | --- |
| `dockerTools.caCertificates` | `default.nix:983-991` | `/etc/ssl/certs/ca-bundle.crt`, `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt` |
| `dockerTools.fakeNss` | `default.nix:966`, impl `pkgs/by-name/fa/fakeNss/package.nix:16-29` | `/etc/passwd` (root + nobody), `/etc/group`, `/etc/nsswitch.conf`, `/var/empty` |
| `dockerTools.binSh` | `default.nix:977-980` | `/bin/sh` → bash |
| `dockerTools.usrBinEnv` | `default.nix:970-973` | `/usr/bin/env` for `#!` lines |

What upstream does **not** do:

- **None of those four are included by default.** `streamLayeredImage`'s
  argument list (`default.nix:1004-1034`) has no `caCertificates`, no `nss`,
  no `user`. A `buildLayeredImage` with only your app in `contents` has an
  empty `/etc` and no `/tmp`.
- **It does not set a single environment variable for you.** `config.Env`
  defaults to absent, so `$PATH` inside the image is whatever the runtime
  invents (Docker's fallback is `/usr/local/sbin:…:/bin`, none of which exist
  in a store-only image), and `SSL_CERT_FILE` is unset even when you *did* add
  `cacert` — adding the package is not enough, OpenSSL still looks at its
  compiled-in default path.
- **It does not connect `fakeNss` to `config.User`.** You can set
  `config.User = "1000:1000"` and ship no passwd entry; nothing warns you, and
  the container starts. It breaks later, at the first `getpwuid`.
- **`buildImage` and `buildLayeredImage` take different argument names for the
  same thing** — `copyToRoot` (`default.nix:623-624`) versus `contents`
  (`default.nix:1008`) — and `contents` on `buildImage` is deprecated with a
  runtime warning (`default.nix:658`) while `contents` on the layered builders
  is the *correct* name. Switching builders is not a one-word change.

This recipe is a thin function over the upstream builders that wires those
together, asserts the combinations that cannot work, and defaults to the
smallest thing that still runs.

## Traps

### 1. `buildLayeredImage` vs `buildImage`: layering does not shrink the image

The intuition "more layers = smaller image" is wrong, and measurably so. The
same contents, built both ways:

| Build | Layers | `.tar.gz` in the store | Size in the daemon |
| --- | --- | --- | --- |
| `buildLayeredImage` | 10 | 13,259,715 B | 40.8 MB |
| `buildImage` (one flat layer) | 1 | 13,258,868 B | 40.8 MB |

847 bytes apart. Layering buys exactly one thing: **sharing**. Because
`buildLayeredImage` puts one store path per layer (`default.nix:578-603`,
which is just `streamLayeredImage` piped through a compressor), two images
built from overlapping closures share every layer they have in common. On the
daemon used to write this, 15 images whose nominal sizes total ~786 MB occupy
**192.6 MB on disk** — `docker system df` reports 55 % reclaimable. Pushing a
rebuilt app to a registry sends one small layer, not 40 MB.

Choose accordingly:

- **`buildLayeredImage`** — the default. Anything you push to a registry, or
  rebuild often, or run alongside sibling images.
- **`streamLayeredImage`** — same layers, but the derivation output is a
  *script* that writes the tarball to stdout. The multi-hundred-MB tarball
  never enters the store: `$(nix build …)/bin/stream | docker load`. Use it in
  CI, and for large images. The fleet's browser-worker image (chromium + a
  dozen font packages) uses this for exactly that reason.
- **`buildImage`** — one flat layer. Worth it when the consumer counts layers,
  or when you genuinely want a single opaque blob.

Layer-count bounds: `maxLayers` defaults to **100**
(`default.nix:1017`); values ≤ 1 hard-fail an assertion (`default.nix:1036-1039`);
if `fromImage` is set, its layers are subtracted from your budget. When the
closure has more store paths than `maxLayers`, the leftovers are merged into
one layer chosen by a popularity contest — you do not lose paths, you lose
sharing. A `curl` image here came out at **26 layers** for a 26-path closure.

### 2. There is no shell, and that breaks four specific things

`Entrypoint` and `Cmd` in an OCI config are **argv arrays passed to execve** —
there is no shell form, ever. `dockerTools` will not silently give you one.
Concretely, on an image with no `/bin/sh`:

```
$ docker run --rm --entrypoint /bin/sh example-bare:1 -c 'echo hi'
docker: Error response from daemon: failed to create task for container:
  … exec: "/bin/sh": stat /bin/sh: no such file or directory
```

The four things that break, in order of how long they take to notice:

1. **`HEALTHCHECK CMD-SHELL`.** Measured side by side, one image, two configs,
   1 s interval: exec-form `Test = [ "CMD" "${coreutils}/bin/true" ]` →
   `healthy`. Shell-form `Test = [ "CMD-SHELL" "true" ]` → **`unhealthy`**,
   with `docker inspect … .State.Health.Log` full of
   `OCI runtime exec failed: … exec: "/bin/sh": stat /bin/sh: no such file or
   directory`. A shell-form healthcheck does not error at build time and does
   not error at start time — the container comes up and then quietly goes
   unhealthy, which in an orchestrator means a restart loop.
2. **Entrypoint wrapper scripts.** A `#!/bin/sh` script needs both `/bin/sh`
   *and* — if it uses `#!/usr/bin/env sh` — `/usr/bin/env`. Use
   `pkgs.writeShellApplication` instead: it bakes an absolute store-path
   shebang and puts `runtimeInputs` on `PATH`, so it needs neither.
3. **`docker exec -it … sh` / `kubectl exec`.** Debugging is gone. That is the
   trade; keep a `shell = true` variant of the image around, or attach with
   `nsenter` from the host.
4. **Anything that shells out.** `system()`, Python `subprocess(shell=True)`,
   Go `exec.Command("sh", …)`, `git`'s credential helpers.

`shell = true` adds `dockerTools.binSh` + `bashInteractive` — about 55 MB of
bash + its dependencies. That is the honest price.

### 3. CA certificates: the failure message never says "certificates"

Nothing in a Nix-built image sets up TLS trust. The error you get, measured
with `curl` in an image built without `tls`:

```
curl: (60) SSL certificate OpenSSL verify result:
  unable to get local issuer certificate (20)
```

The same image with `tls = true`: `http=200 verify=0`. Other runtimes phrase
the same missing file differently, which is why this is hard to recognise:

- Go: `x509: certificate signed by unknown authority`
- Python/requests: `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`
- Node: `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` / `SELF_SIGNED_CERT_IN_CHAIN`
- JVM: `PKIX path building failed: unable to find valid certification path`

**Adding `pkgs.cacert` to `contents` is not sufficient.** It installs the
bundle under a store path; nothing looks there. You need both the file at a
conventional location (`dockerTools.caCertificates`, `default.nix:983-991`)
and the environment variables pointing at it. This recipe sets `SSL_CERT_FILE`,
`NIX_SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO` and
`REQUESTS_CA_BUNDLE` to `/etc/ssl/certs/ca-bundle.crt`. Go and the JVM read
neither of those and rely on the file locations, which `caCertificates`
provides for the Debian, NixOS and RedHat conventions simultaneously.

To trust an extra CA (a corporate MITM proxy, an internal PKI), concatenate
rather than replace, as a proxy-worker image would:

```nix
caBundle = pkgs.runCommand "ca-bundle" { } ''
  mkdir -p $out/etc/ssl/certs
  cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${./internal-ca.crt} \
    > $out/etc/ssl/certs/ca-bundle.crt
  ln -s ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
'';
# then: tls = false; contents = [ ... caBundle ];
```

### 4. `/etc/passwd` and the non-root user

`config.User = "65532:65532"` works at the kernel level with no `/etc/passwd`
at all — the container starts, the uid is right. What fails is *name*
resolution, later and elsewhere:

```
$ docker run --rm probe-nonss:1          # User=65532:65532, no /etc/passwd
whoami: cannot find name for user ID 65532: No such file or directory
```

With `user = "app"` (which is `fakeNss.override { extraPasswdLines = … }`):

```
$ docker run --rm probe-withnss:1
app
```

The real-world victims of a missing passwd entry are: `nginx`'s `user`
directive, OpenSSH and git (`No user exists for uid`), Go's `os/user`, Java's
`user.name`, anything that expands `~`, and any library that derives a config
path from `$HOME`.

Two related sub-traps:

- **`$HOME` is not set by the runtime.** Docker sets it only from the passwd
  entry in some versions and not in others. This recipe sets `HOME` in
  `config.Env` unconditionally, defaulting to `/var/empty` (the same home
  `fakeNss` gives root and nobody). If the app writes to `$HOME`, point it at a
  volume — `/var/empty` is in a read-only layer.
- **`User` is written numerically, not as a name.** `"65532:65532"` rather
  than `"app"`, so the image still starts if the passwd layer is ever dropped
  or overridden. `getpwuid` degrades; `execve` does not.
- **`/etc/nsswitch.conf`**: `fakeNss` ships `hosts: files dns`
  (`fakeNss/package.nix:26-29`). Measured here, glibc's compiled-in fallback
  was enough for DNS even with no `nsswitch.conf` at all (an image without it
  resolved `example.com` and got `http=200`) — but that fallback is a glibc
  implementation detail that has changed across versions, and it does *not*
  cover `passwd`/`group`. Ship the file; it costs nothing. The fleet's
  torrent-client image installs a hand-written one for this reason.

### 5. Timezone data costs 10 MB unless you copy one file

Adding `pkgs.tzdata` to `contents` and setting `TZDIR` works, and it drags the
entire IANA database into the closure. Measured, same image, same zone:

| `zoneinfo` | How | Image size |
| --- | --- | --- |
| `"full"` | `tzdata` in contents, `TZDIR` + `TZ` set, `/etc/localtime` symlink | 63.9 MB |
| `"single"` | one TZif file copied to `/etc/localtime` | **53.6 MB** |

Both print `Tue Jul 28 21:34 +0845 2026` for `Australia/Eucla`. The 10.3 MB
difference is the other ~600 zones.

The mechanism matters: `install -m 0644 ${tzdata}/share/zoneinfo/<zone>
etc/localtime` **copies** the file, and a TZif blob contains no store-path
references, so Nix's reference scanner does not pull `tzdata` into the closure.
`ln -s` into the store would. This is the whole trick.

The trap in the cheap variant: **do not set `TZ`**. With no `TZDIR` and no zone
database, `TZ=Australia/Eucla` cannot be resolved and glibc silently falls back
to UTC — you get a wrong-but-plausible clock. Unset `TZ` and glibc reads
`/etc/localtime`, which is the file you just copied. Use `zoneinfo = "full"`
only when the app resolves zone names at runtime (per-user timezones, a
scheduler with zone-aware cron expressions).

### 6. `$PATH` in a store-only image

There is no `/usr/bin`. Docker's default `PATH` points at six directories that
do not exist, so any `exec.LookPath`, `subprocess("psql")`, or plugin discovery
fails with `executable file not found in $PATH` even though the binary is in
the image. This recipe computes `PATH` from `lib.makeBinPath contents` and
appends `/bin:/usr/bin` (which do exist when `contents` is non-empty, because
the layered builders symlink package roots into the image root).

Two sharp edges:

- **`lib.makeBinPath [ ]` is the empty string.** Splicing it into
  `"${...}:/bin:/usr/bin"` yields a leading empty element, and an empty element
  in `PATH` means **the current working directory** — a genuine privilege
  escalation vector in a container that runs untrusted input. The recipe
  filters empty components out.
- **Entrypoints should still be absolute store paths.** `lib.getExe pkgs.foo`,
  not `"foo"`. `PATH` is for what the app spawns; the entrypoint should not
  depend on it.

### 7. `buildImage` cannot `mkdir` into a directory that came from a package

This one cost a build failure while writing the recipe:

```
Adding contents...
Adding /nix/store/…-example-single-layer-root
mkdir: cannot create directory 'var/tmp': Permission denied
```

`buildImage`'s `mkPureLayer` rsyncs each content tree into the layer with
`--chown=0:0` (`default.nix:452`), preserving store modes — store directories
are `r-xr-xr-x` — and then chmods **only the layer root** writable
(`default.nix:458`). So `extraCommands` can create top-level directories but
not descend into any directory a package contributed. Here `fakeNss` provides
`/var/empty`, so `var` existed read-only and `mkdir -p var/tmp` failed.

`buildLayeredImage` does not hit this: its customisation layer is a
`symlinkJoin`, whose directories are writable. The failure therefore appears
only when you switch builders — which is precisely when you are least
expecting a new error. The recipe emits a `chmod u+w` prelude over `etc`,
`var`, `usr` so the same `extraCommands` work under every builder.

Related: `extraCommands` runs **unprivileged**, so it can set mode bits
(`chmod 1777 tmp` survives into the tarball) but cannot `chown`. For ownership
you need `fakeRootCommands`, and for anything that must *look* like a real root
filesystem while it runs, `enableFakechroot = true` — which uses `proot` and
therefore hard-fails on Darwin with an explicit assertion
(`default.nix:1040-1048`). `buildImage`'s `runAsRoot` is a third mechanism
again: it boots a **QEMU VM** (`mkRootLayer`, `default.nix:482-509`), which the
layered builders do not support at all.

### 8. Reproducibility: `created`, `mtime`, `tag`, and lowercase names

- `created` and `mtime` both default to `"1970-01-01T00:00:01Z"`
  (`default.nix:644` for `buildImage`, `default.nix:1011-1012` for
  `streamLayeredImage`). Verified: `docker inspect --format '{{.Created}}'`
  returns `1970-01-01T00:00:01Z`. Tooling that sorts images by creation date
  will show them all as equally ancient — that is the cost of the guarantee,
  and it is worth it.
- `created = "now"` **breaks reproducibility**, and does so in a
  counter-intuitive way: for `buildImage` it is implemented as a `runCommand`
  that shells out to `date` (`default.nix:680-690`). That derivation is
  cached like any other, so the timestamp is frozen at *whenever the build
  first happened on this machine* — not "now", and different on every machine.
  Prefer a `Labels` entry with the git revision.
- `mtime` is not just cosmetic: a non-constant mtime changes every layer hash,
  so every rebuild re-uploads every layer.
- **`tag = null`** makes the tag the output hash (`default.nix:743-749`,
  `1173-1179`). Excellent for immutable deployments, but the tag changes
  whenever anything in the closure does, so nothing can pin `myapp:latest`.
- **The image name is lowercased** for `imageName` (`default.nix:737` and
  `1171`), while the *tarball* keeps your capitalisation. `name = "MyApp"`
  therefore produces `MyApp.tar.gz` that loads as `myapp`. The recipe asserts
  the name is already lowercase rather than letting the two drift.
- `includeStorePaths = false` (`default.nix:1021`, default `true`) produces an
  image containing only symlinks. It runs *only* if the host store is
  bind-mounted in; upstream documents this as "not recommended … the generated
  image won't run properly". Do not reach for it as a size optimisation.

## Measurements

All built from one nixpkgs checkout, `x86_64-linux`, loaded into Docker.
"Store" is the compressed `.tar.gz` in the Nix store; "daemon" is what
`docker images` reports (uncompressed).

| Image | Contents | Layers | Store | Daemon |
| --- | --- | --- | --- | --- |
| `bare` | one dynamically-linked binary + glibc, nothing else | 6 | 12.99 MB | 40.1 MB |
| `service` | same + CA bundle + passwd/group/nsswitch + `/tmp` + non-root + timezone | 10 | 13.26 MB | 40.8 MB |
| `singleLayer` | same as `service`, via `buildImage` | 1 | 13.26 MB | 40.8 MB |
| `tlsClient` | `curl` and its full closure | 26 | 24.39 MB | 71.2 MB |
| static busybox | `pkgsStatic.busybox`, no libc in the image | 2 | **0.83 MB** | **2.34 MB** |

Two things to read off this table:

1. **The whole hygiene checklist costs 0.7 MB** (12.99 → 13.26 MB). There is no
   size argument for shipping a broken image.
2. **The floor for a dynamically-linked image is glibc**, ~38 MB uncompressed,
   and no amount of layer tuning moves it. If you need genuinely tiny, the
   lever is `pkgsStatic` (or a static Go/Rust binary), not the image builder:
   0.83 MB versus 12.99 MB, a 15× difference, from changing the *package*.
   `pkgsStatic` builds a lot from source, so weigh build time against it.

## Usage

```nix
let
  oci = import ./lib/minimal-oci-image { inherit pkgs; };
in
{
  # The realistic default: non-root, TLS-capable, /tmp, local timezone.
  myImage = oci.mkMinimalImage {
    name       = "myapp";                       # must be lowercase
    tag        = "1.4.2";
    entrypoint = [ (lib.getExe pkgs.myapp) "--config" "/etc/myapp.toml" ];
    contents   = [ pkgs.myapp ];                # puts bin/ on $PATH too
    user       = "app";
    timezone   = "Europe/Berlin";
    exposedPorts = { "8080/tcp" = { }; };
    env.MYAPP_LOG_FORMAT = "json";
    labels."org.opencontainers.image.revision" = self.rev or "dirty";
  };

  # CI variant: never materialise the tarball in the store.
  myImageStream = oci.mkMinimalImage {
    name = "myapp"; tag = "1.4.2"; builder = "stream";
    entrypoint = [ (lib.getExe pkgs.myapp) ];
    user = "app";
  };
}
```

```console
$ docker load < $(nix-build -A myImage)          # layered / single
$ $(nix-build -A myImageStream) | docker load    # stream
```

### Options

| Option | Default | Purpose |
| --- | --- | --- |
| `name` | — | Image name; asserted lowercase. |
| `tag` | `"latest"` | `null` ⇒ tag derived from the output hash. |
| `entrypoint` / `cmd` | `[ ]` | argv arrays. No shell form exists. |
| `contents` | `[ ]` | Packages whose trees land in `/` and whose `bin/` joins `$PATH`. |
| `env` | `{ }` | Attrset merged over the computed defaults (attrset, so overrides replace rather than duplicate). |
| `builder` | `"layered"` | `layered` \| `stream` \| `single`. |
| `maxLayers` | `100` | Layered builders only. |
| `tls` | `true` | CA bundle at three conventional paths + five env vars. |
| `nss` | `true` | `/etc/passwd`, `/etc/group`, `/etc/nsswitch.conf`, `/var/empty`. |
| `user` / `uid` / `gid` | `null` / `65532` / `65532` | Non-root user with a real passwd entry; `User` is written numerically. |
| `home` | `"/var/empty"` | `$HOME`. Read-only — mount a volume if the app writes there. |
| `shell` | `false` | `/bin/sh` + bash. Needed for `CMD-SHELL` healthchecks and `docker exec … sh`. |
| `coreutils` / `usrBinEnv` | `false` | Debug aids. |
| `timezone` | `null` | IANA zone name. |
| `zoneinfo` | `"single"` | `"single"` copies one TZif (no `tzdata` in the closure); `"full"` ships the database (+10 MB). |
| `tmp` | `true` | `/tmp` and `/var/tmp`, mode `1777`. |
| `created` / `mtime` | epoch | Keep them. |
| `extraCommands` | `""` | Runs in the image root, unprivileged, after a `chmod u+w` prelude. |
| `extraConfig` | `{ }` | Merged over the OCI config; the escape hatch for `Healthcheck`, `StopSignal`, `Shell`. |
| `extraArgs` | `{ }` | Passed to the underlying dockerTools builder (`fromImage`, `fakeRootCommands`, `enableFakechroot`, `includeNixDB`). |

Assertions fire at eval time for: a non-lowercase `name`; `user` set with
`nss = false`; an unknown `zoneinfo` or `builder`.

## Caveats

- **`docker load` needs a running daemon; `nix build` does not.** The image is
  a tarball in the store, reproducible and cacheable. Getting it *onto* a host
  is out of scope — `docker load`, `skopeo copy`, or a registry push.
- **Cross-architecture images are not cross-builds.** `architecture` only
  writes a field in the OCI config; the binaries still come from whatever
  `pkgs` you passed. For a real arm64 image, pass an arm64 `pkgs`
  (`pkgsCross.aarch64-multiplatform` or a native remote builder).
- **Kubernetes `readinessProbe: exec` has the same shell problem** as
  `HEALTHCHECK CMD-SHELL`. `httpGet` probes do not, because the kubelet makes
  the request itself — prefer them in shell-less images.
- **Nothing here is a security boundary.** Non-root plus no shell raises the
  cost of a foothold; it is not a sandbox. Add `--read-only`,
  `--cap-drop=ALL`, `--security-opt=no-new-privileges`, seccomp, and a user
  namespace at *run* time.
- **`includeNixDB`** (via `extraArgs`) is only for images that run `nix`
  itself; it inflates the image and upstream warns that only the deepest
  layer's database is loaded (`default.nix:65-68`).
