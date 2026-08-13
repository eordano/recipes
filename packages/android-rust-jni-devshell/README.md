# android-rust-jni-devshell

A `nix develop` / `nix-shell` that both **compiles and emulates** an Android app
whose native code is a **Rust JNI crate**. The app module (Gradle + AGP) loads a
Rust `cdylib` through JNI -- `System.loadLibrary("myapp_jni")` -- built by
cargo-ndk, and this shell also ships a headless emulator so the resulting APK can
actually be launched, not just fed to the JVM unit tests. `myapp` is a
placeholder; point `appName` at your own module.

## The problem

An Android app with a Rust JNI layer has two toolchains that must agree, and the
usual ways they *fail* to agree are both **silent**:

1. **The native library is never built.** `cargo-ndk` on `PATH` makes the Gradle
   task look wired up, but a stock `rustc` ships only the *host* std. Crucially,
   `rustc --print target-list` lists `aarch64-linux-android` /
   `x86_64-linux-android` whether or not their std libraries are actually
   installed -- so nothing warns you. The cross-compile then fails at **link
   time**, `app/src/main/jniLibs/` is never created, and the APK ships with no
   `.so` inside it. `System.loadLibrary(...)` throws at runtime. The JVM unit
   tests stay green the whole time because they never load the library.

2. **The app can be compiled but never run.** Without an emulator and a system
   image, only the host-side JVM tests work. Instrumented tests, and any check
   of what the app looks like on a screen, are impossible -- which is exactly how
   the missing-`.so` gap in (1) survives unnoticed. A toolchain that builds an
   app it cannot launch hides its own bugs, so the emulator lives in *this*
   shell rather than a separate one.

## The approach

One `mkShell` with everything both toolchains need:

- **rust-overlay** for the Rust toolchain, `.override { targets = [...]; }` to
  install the Android std libraries -- the fix for problem (1).
- **`androidenv.composeAndroidPackages`** pinning the SDK platform, a matching
  build-tools, the NDK, an emulator, and a `google_apis` x86_64 system image --
  the fix for problem (2).
- Two ABIs in the default `abis`: **x86_64** so the crate's `.so` runs *inside*
  the emulator (an x86_64 image under KVM -- fast; see trap 6), and
  **arm64-v8a** so the same build also yields an artifact installable on a real
  phone. cargo-ndk cross-compiles both.
- Three tiny `writeShellScriptBin` helpers -- `<app>-avd`, `<app>-emulator`,
  `<app>-wait-boot` -- to create the AVD, boot it headless, and block until
  `sys.boot_completed=1`.

A `callPackage`-style function; it needs a `pkgs` with rust-overlay applied and
the Android license accepted:

```nix
let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [ (import rust-overlay) ];
    config.android_sdk.accept_license = true;
  };
in
pkgs.callPackage ./default.nix { appName = "myapp"; }
```

Wire the result into a flake `devShells.<system>.default` and run `nix develop`,
or `nix-shell` it directly.

## Traps

Seven generic failures, each of which cost a build.

1. **Missing Android Rust std target.** The single reason this file exists.
   cargo-ndk cannot link without the target's std libraries, and nothing on
   `PATH` tells you they are absent -- `rustc --print target-list` lists the
   triple regardless. Supply them with rust-overlay:
   `rust-bin.stable.latest.default.override { targets = [ "aarch64-linux-android" "x86_64-linux-android" ]; }`.

2. **`buildToolsVersion` must match the SDK component you installed.** The
   `buildToolsVersion` in `composeAndroidPackages` and the one in the app
   module's `build.gradle.kts` are load-bearing in *both* directions. AGP does
   not negotiate: ask for a version that was not installed and it tries to
   download it **into the nix store**, failing with `The SDK directory is not
   writable` before it compiles anything. Keep `compileSdk` / `targetSdk` /
   `platformVersion` and the build-tools version in lockstep.

3. **`aapt2FromMavenOverride`.** AGP downloads a prebuilt `aapt2` binary whose
   ELF interpreter (`/lib64/ld-linux-*`) does not exist on Nix, so it fails to
   exec. Point AGP at the `aapt2` that ships inside the pinned build-tools with
   `-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/<ver>/aapt2`
   (set here via `GRADLE_OPTS`). Every Android build in the shell needs it.

4. **Derive `JAVA_HOME`, do not hardcode it.** The JDK directory layout differs
   by platform -- Linux at `$jdk/lib/openjdk`, macOS (Zulu) at
   `$jdk/.../Contents/Home`. A hardcoded Linux path makes Gradle abort on darwin
   with `JAVA_HOME is set to an invalid directory`. Derive it from the `java` on
   `PATH`: `export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"`.

5. **The emulator needs `google_apis` images, not `google_apis_playstore`.**
   Play Store images refuse `adb root`, which instrumented debugging needs. At
   the other extreme, plain `default` images carry no Google API shims and some
   AndroidX test infrastructure expects them. `systemImageTypes = [ "google_apis" ]`
   is the middle ground. (The image is ~1.5 GB -- the price of
   `includeSystemImages = true`.)

6. **KVM availability guard.** Without `/dev/kvm` the emulator falls back to full
   software CPU emulation and takes many minutes to boot, or wedges. The
   `<app>-emulator` helper fails closed and loud when `/dev/kvm` is absent rather
   than letting a check hang. On the host, put your user in the `kvm` group and
   enable nested virtualization if the shell runs inside a VM/container.

7. **The shell banner must go to stderr.** `nix develop --command <prog>` is a
   legitimate way to run a program under this toolchain, and some of those
   programs speak a protocol on **stdout** (a JSON-RPC server, a test harness
   piping structured results). A few lines of banner ahead of that stream is a
   parse error the client typically surfaces only as `connection closed`. Every
   `echo` in the `shellHook` -- and in the helper scripts -- writes to `>&2`.

### Emulator flags

`<app>-emulator` boots with `-no-window -no-audio -no-snapshot -gpu
swiftshader_indirect -no-boot-anim`. `-no-window` assumes ssh/CI; drop it (or use
`-gpu host`) when a display is available. `-no-snapshot` trades a few seconds of
boot for reproducibility. Extra args after the AVD name pass straight through.

## Adapting

Change `appName` (renames every helper script and the loaded `.so`), point
`buildToolsVersion` / `platformVersion` / `ndkVersion` at whatever your module
targets -- keeping trap (2) in mind -- and confirm your `build.gradle.kts` calls
cargo-ndk for the same ABIs in `abis`. Everything else carries over unchanged.
