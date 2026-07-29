# installer-iso-secrets-partition
#
# A NixOS installer ISO whose credentials do NOT live in the image.
#
# The image is a pure, cacheable, shareable artifact. Every secret it needs at
# boot (mesh-VPN pre-auth key, private-forge SSH identity, ...) lives on a
# SEPARATE LABELLED PARTITION appended to the USB stick after the hybrid ISO has
# been dd'd onto it. A boot-time oneshot polls for that label, mounts it
# read-only at a tmpfs path, and orders itself BEFORE the units that consume the
# credentials. If the partition is absent the unit exits 0 and the very same
# image still boots as a plain rescue disk.
#
# The other half of the recipe is the flasher: `flasher.package` builds the ISO,
# dd's it, appends the labelled partition to whatever disk label the hybrid
# image left behind, formats it and copies the (age-decrypted) secrets straight
# onto it — never through the Nix store.
#
# See README.md for the five traps: the world-readable-image trap, the GPT
# backup-header trap, the mkImageMediaOverride password-priority trap, copytoram,
# and partition-node settling.
#
# Usage:
#   imports = [ ./installer-iso-secrets-partition ];
#   modules.installerSecretsPartition = {
#     enable = true;
#     label = "INSTALLER-SEC";
#     secretFiles = {
#       vpnAuthKey = "vpn-auth";
#       forgeKey   = "forge-id_ed25519";
#     };
#     before = [ "tailscaled.service" ];
#     flasher.enable = true;
#   };
#   services.tailscale.authKeyFile =
#     config.modules.installerSecretsPartition.paths.vpnAuthKey;

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.installerSecretsPartition;

  # "installer-secrets-mount" -> "installer-secrets". Only used to prefix the
  # unit's journal lines so they are greppable by the same name as the unit.
  logPrefix = lib.removeSuffix "-mount" cfg.unitName;

  # The label is looked up with `blkid -L`, i.e. by FILESYSTEM label, not by GPT
  # partition name. That is deliberate — see README ("MBR loses nothing").
  mountScript = pkgs.writeShellScript cfg.unitName ''
    set -euo pipefail
    mkdir -p ${cfg.mountPoint}
    if ${pkgs.util-linux}/bin/mountpoint -q ${cfg.mountPoint}; then
      echo "${logPrefix}: already mounted"
      exit 0
    fi
    for i in $(seq 1 ${toString cfg.pollAttempts}); do
      DEV=$(${pkgs.util-linux}/bin/blkid -L ${cfg.label} 2>/dev/null || true)
      [ -n "$DEV" ] && break
      sleep ${cfg.pollIntervalSeconds}
    done
    if [ -z "$DEV" ]; then
      echo "${logPrefix}: ${cfg.label} partition not found — running without baked-in secrets"
      exit ${if cfg.optional then "0" else "1"}
    fi
    ${pkgs.util-linux}/bin/mount \
      -o ${lib.concatStringsSep "," cfg.mountOptions} \
      "$DEV" ${cfg.mountPoint}
    echo "${logPrefix}: mounted $DEV at ${cfg.mountPoint}"
  '';

  sshHostModule = lib.types.submodule {
    options = {
      patterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "`Host` patterns/aliases this block matches.";
        example = [
          "forge"
          "forge.example.com"
        ];
      };
      hostName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "`HostName` to dial. Null omits the directive.";
      };
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "`User` for this block. Null omits the directive.";
      };
      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "`Port` for this block. Null omits the directive.";
      };
      identityFile = lib.mkOption {
        type = lib.types.str;
        description = ''
          Private key to authenticate with. Point this at a file on the secrets
          partition, e.g. `config.modules.installerSecretsPartition.paths.forgeKey`,
          so no key material ends up in the image.
        '';
        example = "/run/installer-secrets/forge-id_ed25519";
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra ssh_config directives appended inside this block.";
      };
    };
  };

  renderSshHost =
    h:
    let
      line = k: v: lib.optionalString (v != null) "  ${k} ${toString v}\n";
    in
    "Host ${lib.concatStringsSep " " h.patterns}\n"
    + line "HostName" h.hostName
    + line "User" h.user
    + line "Port" h.port
    + "  IdentityFile ${h.identityFile}\n"
    + "  IdentitiesOnly yes\n"
    + "  StrictHostKeyChecking ${cfg.strictHostKeyChecking}\n"
    + lib.optionalString (h.extraConfig != "") (
      lib.concatMapStrings (l: "  ${l}\n") (lib.splitString "\n" (lib.removeSuffix "\n" h.extraConfig))
    );

  secretNames = lib.attrValues cfg.secretFiles;

  flasher = pkgs.writeShellApplication {
    name = cfg.flasher.name;
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
      gptfdisk
      e2fsprogs
      dosfstools
      parted
      systemd
      gawk
      gnused
    ];
    # `nix`, `sudo` and `age`/`rage` are deliberately NOT runtimeInputs: they
    # come from the operator's own environment, so the flasher uses the same nix
    # daemon, the same sudo policy and the same (possibly hardware-backed) age
    # implementation the operator already trusts.
    text = ''
      # ${cfg.flasher.name} — build the installer ISO, dd it to a removable
      # device, then APPEND a labelled partition holding the out-of-band
      # secrets. Nothing secret ever enters the Nix store or the image.

      RED=$'\033[0;31m'
      GRN=$'\033[0;32m'
      YLW=$'\033[1;33m'
      CYN=$'\033[0;36m'
      NC=$'\033[0m'
      info() { printf '%s[INFO]%s %s\n'     "$CYN" "$NC" "$1"; }
      ok()   { printf '%s[OK]%s %s\n'       "$GRN" "$NC" "$1"; }
      warn() { printf '%s[WARN]%s %s\n'     "$YLW" "$NC" "$1"; }
      err()  { printf '%s[ERROR]%s %s\n'    "$RED" "$NC" "$1" >&2; }
      step() { printf '\n%s[STEP]%s %s\n\n' "$CYN" "$NC" "$1"; }

      # Run privileged. Not `SUDO=sudo; $SUDO cmd` — an unquoted variable in
      # command position is exactly the pattern that breaks on empty values.
      run() {
        if [ "$(id -u)" -eq 0 ]; then
          "$@"
        else
          sudo "$@"
        fi
      }

      FLAKE_ATTR=${lib.escapeShellArg cfg.flasher.isoAttr}
      LABEL=${lib.escapeShellArg cfg.label}
      SIZE_MIB=${toString cfg.flasher.partitionSizeMiB}
      FSTYPE=${lib.escapeShellArg cfg.flasher.filesystem}
      IDENTITY=${lib.escapeShellArg cfg.flasher.ageIdentityFile}
      AGE_DIR=${lib.escapeShellArg cfg.flasher.ageSecretsDir}
      MOUNT_UNIT=${lib.escapeShellArg cfg.unitName}
      ISO=""
      PLAIN_DIR=""
      DEVICE=""
      TMP_SECRETS=""
      MNT=""
      BUILD=true
      WRITE=true
      WITH_SECRETS=true
      ASSUME_YES=false
      declare -a SECRETS=(${lib.concatStringsSep " " (map lib.escapeShellArg secretNames)})

      usage() {
        cat <<EOF
      Usage: $(basename "$0") [OPTIONS] [DEVICE]

      Build the installer ISO, write it to a removable device, then append a
      partition labelled "$LABEL" holding the secrets the booted installer
      mounts out-of-band. Secrets are decrypted with your age identity and
      copied straight onto that partition: they never enter the Nix store and
      are not part of the ISO.

      Options:
        --iso PATH          Use this ISO file instead of building one
        --attr ATTR         Flake attribute to build (default: $FLAKE_ATTR)
        --label NAME        Filesystem label for the secrets partition
                            (default: $LABEL; ext4 caps labels at 16 bytes,
                            FAT at 11)
        --size MIB          Size of the secrets partition (default: $SIZE_MIB)
        --fs TYPE           ext4 (default) or vfat
        --identity FILE     Age identity used to decrypt (default: $IDENTITY)
        --age-dir DIR       Directory holding <name>.age files (default: $AGE_DIR)
        --secret NAME       Secret to place on the partition; repeatable.
                            First use replaces the built-in default list.
        --plaintext-dir DIR Copy every regular file in DIR onto the partition
                            verbatim instead of decrypting anything
        --build-only        Build the ISO and stop
        --skip-build        Do not build; use the last built artefact
        --no-secrets        Flash the ISO only, no secrets partition
        --yes               Do not ask before destroying DEVICE
        --help              This text
      EOF
      }

      cleanup() {
        if [ -n "$MNT" ] && mountpoint -q "$MNT" 2>/dev/null; then
          run umount "$MNT" >/dev/null 2>&1 || true
        fi
        [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null
        [ -n "$TMP_SECRETS" ] && rm -rf "$TMP_SECRETS"
        return 0
      }
      trap cleanup EXIT

      user_secrets=false
      while [ $# -gt 0 ]; do
        case "$1" in
          --iso)           ISO=''${2:-};        shift 2 ;;
          --attr)          FLAKE_ATTR=''${2:-}; shift 2 ;;
          --label)         LABEL=''${2:-};      shift 2 ;;
          --size)          SIZE_MIB=''${2:-};   shift 2 ;;
          --fs)            FSTYPE=''${2:-};     shift 2 ;;
          --identity)      IDENTITY=''${2:-};   shift 2 ;;
          --age-dir)       AGE_DIR=''${2:-};    shift 2 ;;
          --plaintext-dir) PLAIN_DIR=''${2:-};  shift 2 ;;
          --secret)
            if [ "$user_secrets" = false ]; then
              SECRETS=()
              user_secrets=true
            fi
            SECRETS+=("''${2:-}")
            shift 2
            ;;
          --build-only)    WRITE=false; WITH_SECRETS=false; shift ;;
          --skip-build)    BUILD=false; shift ;;
          --no-secrets)    WITH_SECRETS=false; shift ;;
          --yes|-y)        ASSUME_YES=true; shift ;;
          --help|-h)       usage; exit 0 ;;
          /dev/*)          DEVICE="$1"; shift ;;
          *) err "unknown argument: $1"; usage; exit 1 ;;
        esac
      done

      # /dev/sdb2, but /dev/nvme0n1p2, /dev/mmcblk0p2, /dev/loop0p2. Get this
      # wrong and you format the wrong node — or none at all.
      part_for() {
        case "$1" in
          /dev/nvme*|/dev/mmcblk*|/dev/loop*) printf '%sp%s\n' "$1" "$2" ;;
          *) printf '%s%s\n' "$1" "$2" ;;
        esac
      }

      settle() {
        run partprobe "$1" >/dev/null 2>&1 || true
        run udevadm settle --timeout=10 >/dev/null 2>&1 || sleep 2
      }

      # ---- build -------------------------------------------------------------

      if [ -z "$ISO" ]; then
        if [ "$BUILD" = true ]; then
          step "Building $FLAKE_ATTR"
          out=$(nix build "$FLAKE_ATTR" --no-link --print-out-paths)
        else
          step "Skipping build (--skip-build)"
          out=$(nix path-info "$FLAKE_ATTR" 2>/dev/null || true)
        fi
        # The artefact filename tracks nixpkgs (iso-image.nix names the file
        # from image.baseName, NOT image.fileName), so never guess it — take
        # whatever single .iso the derivation produced.
        if [ -n "$out" ]; then
          ISO=$(find "$out/iso" -maxdepth 1 -name '*.iso' -print -quit 2>/dev/null || true)
        fi
      fi

      if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
        err "no ISO found — build first, or pass --iso PATH"
        exit 1
      fi
      ok "ISO: $ISO ($(numfmt --to=iec "$(stat --printf='%s' "$ISO")"))"

      if [ "$WRITE" = false ]; then
        info "Build complete. Flash it with: $(basename "$0") --skip-build /dev/sdX"
        exit 0
      fi

      # ---- pick the device ---------------------------------------------------

      step "Selecting target device"
      if [ -z "$DEVICE" ]; then
        info "Removable / USB block devices:"
        lsblk -d -o NAME,SIZE,MODEL,TRAN,RM -p | awk 'NR==1 || $4=="usb" || $5=="1"'
        read -rp "Device (e.g. /dev/sdb): " DEVICE
      fi
      [ -b "$DEVICE" ] || { err "$DEVICE is not a block device"; exit 1; }

      case "$DEVICE" in
        /dev/nvme*)
          err "refusing to write to NVMe $DEVICE (almost certainly the system disk)"
          exit 1
          ;;
      esac
      root_dev=$(findmnt -no SOURCE / 2>/dev/null | sed 's/[0-9]*$//; s/p$//')
      if [ -n "$root_dev" ] && [ "$DEVICE" = "$root_dev" ]; then
        err "refusing to write to $DEVICE — that is the root filesystem's device"
        exit 1
      fi

      lsblk "$DEVICE" || true
      warn "ALL DATA ON $DEVICE WILL BE DESTROYED"
      if [ "$ASSUME_YES" != true ]; then
        read -rp "Type 'yes' to continue: " confirm
        [ "$confirm" = "yes" ] || { err "cancelled"; exit 1; }
      fi

      # ---- collect the secrets BEFORE touching the disk ----------------------
      #
      # Decrypt first so a missing key, a missing .age file or an unplugged
      # hardware token fails while the stick is still intact.

      if [ "$WITH_SECRETS" = true ]; then
        step "Collecting secrets"
        TMP_SECRETS=$(mktemp -d)
        chmod 0700 "$TMP_SECRETS"
        if [ -n "$PLAIN_DIR" ]; then
          [ -d "$PLAIN_DIR" ] || { err "no such directory: $PLAIN_DIR"; exit 1; }
          find "$PLAIN_DIR" -maxdepth 1 -type f -exec cp -- {} "$TMP_SECRETS/" \;
        else
          [ -f "$IDENTITY" ] || { err "age identity not found: $IDENTITY"; exit 1; }
          AGE=$(command -v rage || command -v age || true)
          [ -n "$AGE" ] || { err "neither 'rage' nor 'age' on PATH"; exit 1; }
          for name in "''${SECRETS[@]}"; do
            src="$AGE_DIR/$name.age"
            [ -f "$src" ] || { err "missing $src"; exit 1; }
            info "decrypting $name (touch your hardware token if it asks)"
            "$AGE" -d -i "$IDENTITY" -o "$TMP_SECRETS/$name" "$src" \
              || { err "failed to decrypt $name with $IDENTITY"; exit 1; }
          done
        fi
        chmod 0400 "$TMP_SECRETS"/* 2>/dev/null || true
        ok "collected $(find "$TMP_SECRETS" -maxdepth 1 -type f | wc -l) secret(s)"
      fi

      # ---- dd ----------------------------------------------------------------

      step "Writing ISO to $DEVICE"
      for part in "$DEVICE"?*; do
        [ -b "$part" ] || continue
        run umount "$part" >/dev/null 2>&1 || true
      done
      run dd if="$ISO" of="$DEVICE" bs=4M status=progress oflag=sync conv=fsync
      settle "$DEVICE"
      ok "ISO written"

      if [ "$WITH_SECRETS" != true ]; then
        ok "done — no secrets partition requested"
        exit 0
      fi

      # ---- append the secrets partition --------------------------------------
      #
      # A hybrid ISO9660 image dd'd onto a stick usually leaves an MBR ("dos")
      # label whose partition 1 starts at sector 0 and spans the whole image,
      # with the EFI system partition nested inside it. sgdisk rejects that
      # outright — a GPT partition may not start at sector 0 — so `sgdisk
      # --print` exits 2 with "Invalid partition data!", which under
      # `set -o pipefail` kills the script. Detect the label the device really
      # has and append with the matching tool. `sfdisk --append` rewrites only
      # the table entries, leaving partitions 1/2 and the isohybrid boot code
      # intact.

      step "Appending the $LABEL partition"
      label_type=$(run sfdisk --list "$DEVICE" 2>/dev/null \
        | awk -F': *' '/^Disklabel type/ { print $2 }')
      info "disk label on $DEVICE: ''${label_type:-unknown}"

      next=$(run sfdisk --list "$DEVICE" 2>/dev/null \
        | awk -v dev="$DEVICE" '
            index($1, dev) == 1 {
              n = $1; sub("^" dev "p?", "", n)
              if (n ~ /^[0-9]+$/ && n + 0 > m) m = n + 0
            }
            END { print m + 1 }')
      info "creating partition $next ($SIZE_MIB MiB, label $LABEL)"

      if [ "$label_type" = "gpt" ]; then
        # THE TRAP: dd of a hybrid image copies the GPT backup header to
        # wherever the *image* ended — the middle of a larger stick. sgdisk
        # will then write a table whose backup copy is in the wrong place:
        # silent corruption that only shows up at boot. Relocate the backup
        # header to the true end of the device FIRST.
        run sgdisk --move-second-header "$DEVICE" >/dev/null 2>&1 || true
        run sgdisk \
          --new="$next:-''${SIZE_MIB}M:0" \
          --typecode="$next:8300" \
          --change-name="$next:$LABEL" \
          "$DEVICE" >/dev/null
      else
        printf 'size=%s, type=83\n' "$(( SIZE_MIB * 2048 ))" \
          | run sfdisk --append "$DEVICE" >/dev/null
      fi

      settle "$DEVICE"

      SEC_PART=$(part_for "$DEVICE" "$next")
      for _ in $(seq 1 10); do
        [ -b "$SEC_PART" ] && break
        sleep 1
      done
      [ -b "$SEC_PART" ] || { err "partition node $SEC_PART never appeared"; exit 1; }

      info "formatting $SEC_PART as $FSTYPE, label $LABEL"
      case "$FSTYPE" in
        vfat) run mkfs.vfat -n "$LABEL" "$SEC_PART" >/dev/null ;;
        *)    run mkfs.ext4 -q -F -L "$LABEL" "$SEC_PART" >/dev/null ;;
      esac

      # ---- populate ----------------------------------------------------------

      step "Populating $LABEL"
      MNT=$(mktemp -d)
      run mount "$SEC_PART" "$MNT"
      for f in "$TMP_SECRETS"/*; do
        [ -f "$f" ] || continue
        run install -m 0400 -o 0 -g 0 "$f" "$MNT/$(basename "$f")"
        info "  $(basename "$f")"
      done
      run sync
      run umount "$MNT"
      rmdir "$MNT" 2>/dev/null || true
      MNT=""

      ok "stick ready. Boot the target and verify with: systemctl status $MOUNT_UNIT"
    '';
  };
in
{
  options.modules.installerSecretsPartition = {
    enable = lib.mkEnableOption "out-of-band secrets partition for an installer ISO";

    label = lib.mkOption {
      type = lib.types.str;
      default = "INSTALLER-SEC";
      description = ''
        FILESYSTEM label of the secrets partition. Found with `blkid -L`, so the
        GPT partition name is irrelevant and an MBR-labelled stick works just as
        well. ext2/3/4 cap volume labels at 16 bytes and FAT at 11 — keep it
        short and uppercase.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.path;
      default = "/run/installer-secrets";
      description = ''
        Where the partition is mounted. Keep it under `/run` so nothing survives
        a reboot and nothing can be written back to the stick.
      '';
    };

    unitName = lib.mkOption {
      type = lib.types.str;
      default = "installer-secrets-mount";
      description = ''
        Name of the oneshot unit (and of the generated script). Configurable so
        an existing deployment can adopt this module without renaming its unit —
        a rename changes the generated system closure.
      '';
    };

    mountOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ro"
        "nosuid"
        "nodev"
        "uid=0"
        "gid=0"
        "fmask=0177"
        "dmask=0077"
      ];
      description = ''
        Mount options, joined with commas. The defaults are the point of the
        module: read-only so a booted installer cannot rewrite the stick,
        `nosuid,nodev` because this is removable media, and
        `uid=0,gid=0,fmask=0177,dmask=0077` so that on filesystems without unix
        permissions (FAT) the files still land as root-only 0600/0700.
      '';
    };

    pollAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = ''
        How many times to look for the label before giving up. With the default
        interval this is a 10-second budget. See README: the label is NOT
        present when `local-fs.target` is reached, so a single lookup races and
        loses.
      '';
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.str;
      default = "0.5";
      description = "Delay between label lookups, passed verbatim to `sleep`.";
    };

    optional = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When the partition is absent, exit 0 (the default) so the identical
        image still boots as a plain rescue disk. Set false to make a missing
        secrets partition a hard boot failure instead.
      '';
    };

    before = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "tailscaled.service" ];
      example = [
        "tailscale-autoconnect.service"
        "tailscaled.service"
      ];
      description = ''
        Units ordered AFTER the mount, i.e. everything that reads a credential
        from the partition. Getting this list wrong is the failure mode the
        whole design exists to avoid: the VPN daemon starts, finds no key file,
        and the machine silently never joins the mesh.
      '';
    };

    after = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "local-fs.target" ];
      description = ''
        Ordering dependency of the mount unit itself. `local-fs.target` is a
        starting gun, not a guarantee — the poll inside the unit is what
        actually waits for the device.
      '';
    };

    secretFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        vpnAuthKey = "vpn-auth";
        forgeKey = "forge-id_ed25519";
      };
      description = ''
        Logical name -> filename on the partition. Used to compute `paths` and
        to give the flasher its default list of secrets to place.
      '';
    };

    paths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.mapAttrs (_: f: "${cfg.mountPoint}/${f}") cfg.secretFiles;
      defaultText = lib.literalExpression ''mapAttrs (_: f: "''${mountPoint}/''${f}") secretFiles'';
      description = ''
        Absolute paths of the declared secrets, for consumers to reference:
        `services.tailscale.authKeyFile = cfg.paths.vpnAuthKey;`
      '';
    };

    copyToRam = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add the `copytoram` kernel parameter so the whole squashfs is copied
        into RAM at boot and the stick can be pulled out mid-install. Costs
        boot time and RAM proportional to the image.
      '';
    };

    strictHostKeyChecking = lib.mkOption {
      type = lib.types.enum [
        "yes"
        "no"
        "accept-new"
        "ask"
      ];
      default = "accept-new";
      description = ''
        `StrictHostKeyChecking` for the generated `sshHosts` blocks. The default
        trusts the host key seen on first connection, which is what makes an
        unattended installer usable; set `yes` and ship a known_hosts file if
        your threat model includes an active attacker on the install network.
      '';
    };

    sshHosts = lib.mkOption {
      type = lib.types.listOf sshHostModule;
      default = [ ];
      description = ''
        ssh_config `Host` blocks written into `programs.ssh.extraConfig`, each
        pinned to an `identityFile` that lives on the secrets partition. This is
        what lets the installer clone from a private forge without any key
        material in the image.
      '';
      example = lib.literalExpression ''
        [
          {
            patterns = [ "forge" "forge.example.com" ];
            hostName = "forge.example.com";
            user = "git";
            port = 22;
            identityFile = "/run/installer-secrets/forge-id_ed25519";
          }
        ]
      '';
    };

    password = {
      hashedPassword = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "$6$rounds=...$...";
        description = ''
          A real (yescrypt/sha512) password hash for the installer accounts.
          Null leaves upstream's empty-password behaviour alone. This is not a
          secret in the interesting sense — it is a hash on an installer — but
          note it DOES end up world-readable in the store, unlike everything on
          the secrets partition.
        '';
      };
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "root"
          "nixos"
        ];
        description = "Accounts the hash is applied to.";
      };
      priority = lib.mkOption {
        type = lib.types.ints.positive;
        default = 49;
        description = ''
          Definition priority. MUST be below 60: `lib.mkImageMediaOverride` is
          `mkOverride 60` and the installation-device profile sets an empty
          `initialHashedPassword` — anything at 60 or above loses to it (or
          conflicts) and your installer silently keeps an empty password.
        '';
      };
    };

    flasher = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Install the flasher into `environment.systemPackages`. Note the
          flasher belongs on the OPERATOR'S WORKSTATION, not inside the ISO;
          most users take `flasher.package` and expose it from their flake
          instead of enabling this.
        '';
      };
      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = flasher;
        defaultText = lib.literalExpression "pkgs.writeShellApplication { ... }";
        description = "The generated flasher, pre-baked with this module's label, size and secret list.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "flash-installer";
        description = "Executable name of the flasher.";
      };
      isoAttr = lib.mkOption {
        type = lib.types.str;
        default = ".#installer-iso";
        description = "Flake attribute the flasher builds when no `--iso` is given.";
      };
      partitionSizeMiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 16;
        description = ''
          Size of the appended partition. Deliberately tiny: it holds a handful
          of keys, and a small partition carved from the tail of the stick is
          the least likely to collide with anything the image left behind.
        '';
      };
      filesystem = lib.mkOption {
        type = lib.types.enum [
          "ext4"
          "vfat"
        ];
        default = "ext4";
        description = ''
          Filesystem for the secrets partition. `ext4` keeps real unix
          permissions; `vfat` is readable from a non-Linux machine but relies
          entirely on the `uid`/`fmask`/`dmask` mount options for protection.
        '';
      };
      ageIdentityFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "keys/age-yubikey-identity.txt";
        description = "Default age identity the flasher decrypts with (overridable with `--identity`).";
      };
      ageSecretsDir = lib.mkOption {
        type = lib.types.str;
        default = "secrets";
        description = "Directory holding `<name>.age` files (overridable with `--age-dir`).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flasher.filesystem != "ext4" || lib.stringLength cfg.label <= 16;
        message = ''
          modules.installerSecretsPartition.label "${cfg.label}" is ${toString (lib.stringLength cfg.label)}
          bytes; ext2/3/4 volume labels are capped at 16. mkfs.ext4 truncates
          silently, after which `blkid -L` never matches and the installer boots
          with no secrets.
        '';
      }
      {
        assertion = cfg.flasher.filesystem != "vfat" || lib.stringLength cfg.label <= 11;
        message = ''
          modules.installerSecretsPartition.label "${cfg.label}" is ${toString (lib.stringLength cfg.label)}
          bytes; FAT volume labels are capped at 11.
        '';
      }
      {
        assertion = cfg.password.hashedPassword == null || cfg.password.priority < 60;
        message = ''
          modules.installerSecretsPartition.password.priority must be < 60.
          lib.mkImageMediaOverride is mkOverride 60 and the installation-device
          profile sets an empty initialHashedPassword; at >= 60 your hash loses.
        '';
      }
    ];

    systemd.services.${cfg.unitName} = {
      description = "Mount installer secrets partition (label ${cfg.label})";
      wantedBy = [ "multi-user.target" ];
      before = cfg.before;
      after = cfg.after;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = mountScript;
      };
    };

    boot.kernelParams = lib.mkIf cfg.copyToRam [ "copytoram" ];

    programs.ssh.extraConfig = lib.mkIf (cfg.sshHosts != [ ]) (
      lib.concatStringsSep "\n" (map renderSshHost cfg.sshHosts)
    );

    users.users = lib.mkIf (cfg.password.hashedPassword != null) (
      lib.genAttrs cfg.password.users (_: {
        hashedPassword = lib.mkOverride cfg.password.priority cfg.password.hashedPassword;
        initialHashedPassword = lib.mkOverride cfg.password.priority null;
      })
    );

    environment.systemPackages = lib.mkIf cfg.flasher.enable [ cfg.flasher.package ];
  };
}
