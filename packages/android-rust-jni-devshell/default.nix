{
  lib,
  mkShell,
  androidenv,
  rust-bin,
  jdk21,
  cargo-ndk,
  gradle,
  writeShellScriptBin,

  appName ? "myapp",
  jniLibName ? "${appName}_jni",

  platformVersion ? "36",
  buildToolsVersion ? "36.0.0",
  ndkVersion ? "26.3.11579264",

  abis ? [
    "arm64-v8a"
    "x86_64"
  ],
}:

let
  androidComposition = androidenv.composeAndroidPackages {
    cmdLineToolsVersion = "13.0";
    platformToolsVersion = "35.0.2";
    buildToolsVersions = [ buildToolsVersion ];
    platformVersions = [ platformVersion ];
    abiVersions = abis;
    includeNDK = true;
    ndkVersions = [ ndkVersion ];
    includeSources = false;

    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = [ "google_apis" ];
  };

  sdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";

  rustToolchain = rust-bin.stable.latest.default.override {
    targets = [
      "aarch64-linux-android"
      "x86_64-linux-android"
    ];
  };

  avdName = "${appName}-x86_64-${platformVersion}";
  systemImage = "system-images;android-${platformVersion};google_apis;x86_64";
  cmdlineBin = "${sdkRoot}/cmdline-tools/13.0/bin";

  avdCreate = writeShellScriptBin "${appName}-avd" ''
    set -euo pipefail
    name="''${1:-${avdName}}"
    img="${systemImage}"
    if "${cmdlineBin}/avdmanager" list avd 2>/dev/null | grep -q "Name: $name"; then
      echo "avd '$name' already exists" >&2
      exit 0
    fi
    echo "creating avd '$name' from $img" >&2
    echo no | "${cmdlineBin}/avdmanager" create avd \
      --name "$name" --package "$img" --device pixel_6 --force
    echo "created. start it with: ${appName}-emulator" >&2
  '';

  emulatorRun = writeShellScriptBin "${appName}-emulator" ''
    set -euo pipefail
    name="''${1:-${avdName}}"
    # TRAP (6): KVM availability guard. Without /dev/kvm the emulator falls back
    # to full software CPU emulation and takes many minutes to boot (or wedges).
    # Fail closed and loud rather than let a check hang.
    if [ ! -e /dev/kvm ]; then
      echo "no /dev/kvm -- the emulator would fall back to software CPU" >&2
      echo "emulation and take many minutes to boot. Refusing; fix KVM" >&2
      echo "access first (add your user to the 'kvm' group / enable nested" >&2
      echo "virtualization on the host)." >&2
      exit 1
    fi
    # -no-window because this shell is usually driven over ssh/CI; drop it (or
    # pass -gpu host) when a display is available. -no-snapshot keeps boots
    # reproducible, which matters more here than the seconds it costs.
    exec "${sdkRoot}/emulator/emulator" -avd "$name" \
      -no-window -no-audio -no-snapshot -gpu swiftshader_indirect \
      -no-boot-anim "''${@:2}"
  '';

  waitForBoot = writeShellScriptBin "${appName}-wait-boot" ''
    set -euo pipefail
    adb="${sdkRoot}/platform-tools/adb"
    deadline=$(( $(date +%s) + ''${1:-300} ))
    "$adb" start-server >/dev/null 2>&1 || true
    echo "waiting for a device..." >&2
    "$adb" wait-for-device
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if [ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
        echo "boot completed" >&2
        exit 0
      fi
      sleep 2
    done
    echo "device did not finish booting before the deadline" >&2
    exit 1
  '';
in
mkShell {
  packages = [
    androidComposition.androidsdk
    jdk21
    cargo-ndk
    gradle
    rustToolchain
    avdCreate
    emulatorRun
    waitForBoot
  ];

  ANDROID_HOME = sdkRoot;
  ANDROID_SDK_ROOT = sdkRoot;
  ANDROID_NDK_HOME = "${sdkRoot}/ndk/${ndkVersion}";
  ANDROID_NDK_ROOT = "${sdkRoot}/ndk/${ndkVersion}";

  shellHook = ''
    # TRAP (4): derive JAVA_HOME, do not hardcode it. The JDK layout differs by
    # platform -- Linux puts it at $jdk/lib/openjdk, macOS (Zulu) at
    # $jdk/.../Contents/Home. A hardcoded Linux path makes gradle abort on
    # darwin ("JAVA_HOME is set to an invalid directory"). Derive it from the
    # java on PATH so every host works.
    export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"

    # TRAP (3): aapt2FromMavenOverride. AGP downloads a prebuilt aapt2 whose ELF
    # interpreter path does not exist on Nix (no /lib64/ld-linux). Point AGP at
    # the aapt2 that ships inside the pinned build-tools instead. Every Android
    # build in this shell needs this override.
    export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/${buildToolsVersion}/aapt2"

    export ANDROID_AVD_HOME="''${ANDROID_AVD_HOME:-$HOME/.android/avd}"
    mkdir -p "$ANDROID_AVD_HOME"

    # TRAP (7): the banner goes to STDERR, not stdout. `nix develop --command
    # <prog>` is a legitimate way to run a program under this toolchain, and
    # some of those programs speak a protocol on stdout (a JSON-RPC server, a
    # test harness that pipes results). A few lines of banner ahead of it is a
    # parse error the client usually reports only as "connection closed".
    echo "android: sdk ${buildToolsVersion} / ndk ${ndkVersion} / rust w/ android targets" >&2
    echo "  builds lib${jniLibName}.so via cargo-ndk into app/src/main/jniLibs/" >&2
    echo "  ${appName}-avd         create the ${avdName} AVD (once)" >&2
    echo "  ${appName}-emulator    boot it headless (needs /dev/kvm)" >&2
    echo "  ${appName}-wait-boot   block until sys.boot_completed=1" >&2
  '';
}
