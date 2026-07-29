# ssh-write-only-drop-box
#
# A write-only artifact drop-box over SSH. CI boxes rsync a directory in and
# can never read, list, delete or overwrite anything. A systemd path unit
# promotes each completed drop into published/ or moves it into quarantine/
# with a reason file.
#
# The write-only property is enforced at the SSH TRANSPORT layer, not by the
# application, and it takes BOTH halves to hold:
#
#   1. every key gets a forced restricted-rsync command in authorized_keys, and
#   2. a `Match User` block sets `ForceCommand` (which overrides any command=
#      in a key, and any command the client asks for) and narrows
#      `AuthorizedKeysFile` so `~/.ssh/authorized_keys` inside the drop-box
#      tree is not consulted at all.
#
# Half of that pairing is not a weaker version of the whole; it is no
# enforcement at all. See the README.
#
# Drop-in NixOS module. Import it and set `enable`, `dataDir` and `pushKeys`.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sshDropBox;

  rrsyncFlags = lib.concatStringsSep " " (
    [ "-wo" ]
    ++ lib.optional (!cfg.allowDelete) "-no-del"
    ++ lib.optional (!cfg.allowOverwrite) "-no-overwrite"
    ++ lib.optional (!cfg.serializePushes) "-no-lock"
  );

  forcedCommand = "${lib.getExe cfg.rrsyncPackage} ${rrsyncFlags} ${cfg.dataDir}/incoming";

  # `restrict` disables agent/port/X11 forwarding, PTY allocation and
  # ~/.ssh/rc. Deliberately NOT followed by `pty` — rsync never needs a
  # terminal, and re-enabling one hands a shell escape to anything that ever
  # gets to run outside the forced command.
  mkAuthorizedKey = k: ''command="${forcedCommand}",restrict ${k}'';

  mkHook =
    hookName: text:
    if text == "" then
      null
    else
      pkgs.writeShellScript "${cfg.name}-${hookName}" ''
        set -euo pipefail
        ${lib.optionalString (cfg.hookPackages != [ ]) ''
          export PATH=${lib.makeBinPath cfg.hookPackages}''${PATH:+:$PATH}
        ''}
        ${text}
      '';

  validateHook = mkHook "validate" cfg.validate;
  promotedHook = mkHook "on-promoted" cfg.onPromoted;
  quarantinedHook = mkHook "on-quarantined" cfg.onQuarantined;

  promoteScript = pkgs.writeShellApplication {
    name = "${cfg.name}-promote";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
    ];
    text = builtins.readFile ./promote.sh;
  };

  dispatchScript = pkgs.writeShellApplication {
    name = "${cfg.name}-dispatch";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = builtins.readFile ./dispatch.sh;
  };

  pushScript = pkgs.writeShellApplication {
    name = "${cfg.name}-push";
    runtimeInputs = with pkgs; [
      coreutils
      openssh
      rsync
    ];
    text = builtins.readFile ./push.sh;
  };

  workerEnv = {
    DROPBOX_DATA_DIR = cfg.dataDir;
    DROPBOX_SENTINEL = cfg.sentinel;
    DROPBOX_DONE_TIMEOUT = toString cfg.doneTimeoutSec;
    DROPBOX_MAX_ID_LEN = toString cfg.maxIdLength;
  }
  // lib.optionalAttrs (validateHook != null) { DROPBOX_VALIDATE_HOOK = "${validateHook}"; }
  // lib.optionalAttrs (promotedHook != null) { DROPBOX_ON_PROMOTED = "${promotedHook}"; }
  // lib.optionalAttrs (quarantinedHook != null) { DROPBOX_ON_QUARANTINED = "${quarantinedHook}"; };

  orderingDeps = lib.optional (cfg.afterUnit != null) cfg.afterUnit;

  commonHardening = {
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    PrivateDevices = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    LockPersonality = true;
  };

  # The worker never talks to PID 1, so it gets the strict profile.
  # ReadWritePaths only restricts anything when something else has already
  # made the filesystem read-only — hence ProtectSystem=strict alongside it.
  workerHardening = commonHardening // {
    ProtectSystem = "strict";
    ReadWritePaths = [ cfg.dataDir ] ++ cfg.extraReadWritePaths;
  };

  # The dispatcher and the sweep DO talk to PID 1. Connecting to a unix socket
  # needs write access to the socket inode, so ProtectSystem=strict makes
  # /run/systemd/private unreachable and every systemctl call fails. `full`
  # leaves /run writable and still read-onlys /usr, /boot and /etc.
  controlHardening = commonHardening // {
    ProtectSystem = "full";
  };
in
{
  options.services.sshDropBox = {
    enable = lib.mkEnableOption "write-only artifact drop-box over SSH";

    name = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9-]*";
      default = "drop-box";
      description = ''
        Prefix for every unit and helper this module creates:
        `<name>-watch.path`, `<name>-dispatch.service`, `<name>@.service`,
        `<name>-sweep.{service,timer}`.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      example = "/srv/artifacts";
      description = ''
        Root of everything this module manages:

        - `<dataDir>/incoming`   the rsync chroot the push user writes into
        - `<dataDir>/published`  completed, accepted drops
        - `<dataDir>/quarantine` rejected drops, each with a `<id>.reason` file
        - `<dataDir>/work`       per-id lock files

        Keep the whole tree on ONE filesystem. Promotion is a `mv` from
        `incoming/` to `published/`; across a mount boundary that silently
        degrades from an atomic rename into copy-then-delete, and readers see a
        half-populated directory in `published/`.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "dropbox";
      description = "System user that receives pushes and runs the promoter.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "dropbox";
      description = "Primary group of the push user.";
    };

    pushKeys = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = [ ];
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... ci-runner-1" ];
      description = ''
        SSH public keys allowed to push. Each is written into
        `/etc/ssh/authorized_keys.d/<user>` with a forced restricted-rsync
        command and `restrict`.

        The forced command in the key is documentation and defence in depth.
        The enforcement that actually cannot be talked out of is the
        `Match User` / `ForceCommand` block this module also emits.
      '';
    };

    rrsyncPackage = lib.mkPackageOption pkgs "rrsync" { };

    allowDelete = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether pushers may use rsync's `--delete*` / `--remove-*` options
        inside the chroot.

        `rrsync -wo` does NOT imply this restriction: write-only blocks
        `--sender` (reading) and nothing else, so by default a pusher can
        delete another pusher's in-flight drop. Off here adds `-no-del`.
      '';
    };

    allowOverwrite = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether a push may overwrite files that already exist inside the
        chroot. Setting this false adds `rrsync -no-overwrite`, which forces
        `--ignore-existing` server-side.

        Leave it true if pushers ever resume or re-push the same id; with it
        false, a retried push appears to succeed while changing nothing.
      '';
    };

    serializePushes = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep rrsync's exclusive `flock` on the chroot directory, which lets
        only one push run at a time; a second concurrent pusher is rejected
        with "Another instance of rrsync is already accessing this directory."

        Set false (adds `-no-lock`) when many CI runners push at once and you
        would rather have interleaved uploads than failed ones. Note that a
        client pushing payload and sentinel as two runs releases the lock in
        between either way.
      '';
    };

    sentinel = lib.mkOption {
      type = lib.types.str;
      default = ".done";
      description = ''
        Filename the pusher writes LAST, in its own rsync run, to signal a
        complete upload. A leading dot is a good default: systemd path units
        ignore dot-files, so a sentinel named this way can never be mistaken
        for a new drop by the watcher.
      '';
    };

    doneTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        Seconds a worker waits for the sentinel after first seeing a drop.
        On expiry the drop is quarantined with reason
        `incomplete upload: sentinel '<name>' not seen within <n>s`.

        Size this above the slowest realistic upload, not the average one: the
        clock starts when the top-level directory is created, which is at the
        BEGINNING of the transfer.
      '';
    };

    maxIdLength = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = "Maximum drop id length. Longer names are rejected before any path is built from them.";
    };

    validate = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        test -f manifest.json || { echo "missing manifest.json"; exit 1; }
      '';
      description = ''
        Shell run after the sentinel arrives and before the drop moves.
        Runs with the drop as its working directory. A non-zero exit rejects
        the drop; whatever it printed (first 5 lines) becomes the quarantine
        reason.

        This is where per-deployment content rules live — schema checks,
        required files, size limits. The module deliberately has no opinion
        about what a drop contains.
      '';
    };

    onPromoted = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''touch "$DROPBOX_DATA_DIR/.reindex"'';
      description = ''
        Shell run after a drop lands in `published/`. Environment:
        `DROPBOX_ID`, `DROPBOX_DATA_DIR`, `DROPBOX_PATH`.

        A failing hook is logged and ignored — the drop is already promoted,
        and turning that into a failed unit would only hide it.
      '';
    };

    onQuarantined = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Shell run after a drop is rejected. Environment: `DROPBOX_ID`,
        `DROPBOX_DATA_DIR`, `DROPBOX_PATH`, `DROPBOX_REASON`.
      '';
    };

    hookPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.jq ]";
      description = "Packages put on `PATH` for the `validate` / `onPromoted` / `onQuarantined` hooks.";
    };

    extraReadWritePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra paths the promoter may write to. The units run with
        `ProtectSystem=strict`, so a hook that writes outside `dataDir` needs
        its target listed here or it fails with EROFS.
      '';
    };

    afterUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wait-for-storage-pool.service";
      description = ''
        Optional unit that must be up before any drop-box unit runs. Set this
        when `dataDir` lives on storage that is mounted or unlocked by another
        unit; it is added to both `After=` and `Requires=`.
      '';
    };

    manageAllowUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set `services.openssh.settings.AllowUsers = [ user ]` (at `mkDefault`).

        Off by default and it should usually stay off: `AllowUsers` is a global
        allow-list, so turning it on here locks every other account —
        including yours — out of SSH on this host.
      '';
    };

    installClient = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add the `<name>-push` client helper to `environment.systemPackages` on this host.";
    };

    clientPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pushScript;
      defaultText = lib.literalExpression "<the generated push client>";
      description = ''
        The client half, so a pusher host can get it without copying the
        script: `config.services.sshDropBox.clientPackage`, or build it out of
        this repository directly.
      '';
    };

    triggerLimitIntervalSec = lib.mkOption {
      type = lib.types.str;
      default = "10s";
      description = ''
        `TriggerLimitIntervalSec=` on the path unit. See `triggerLimitBurst`.
      '';
    };

    triggerLimitBurst = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 200;
      description = ''
        `TriggerLimitBurst=` on the path unit; 0 disables rate limiting.

        Deliberately not lowered below systemd's own default of 200 per 2s.
        Exceeding the limit does not throttle the watcher — it puts the path
        unit into a FAILED state where it stops watching until something
        restarts it, which turns a burst of pushes into a silently dead
        intake. `sweepInterval` exists to recover from exactly that.
      '';
    };

    sweepInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "5min";
      example = "15min";
      description = ''
        How often to re-arm the watcher and re-scan `incoming/` for drops the
        inotify path missed (events during a restart, a failed path unit, a
        network filesystem). `null` disables the timer.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.pushKeys != [ ];
        message = "services.sshDropBox.pushKeys must list at least one SSH public key.";
      }
      {
        assertion = config.services.openssh.enable;
        message = ''
          services.sshDropBox needs services.openssh.enable = true — the
          write-only property is enforced by sshd, not by this module.
        '';
      }
      {
        assertion = lib.hasPrefix "/" cfg.dataDir;
        message = "services.sshDropBox.dataDir must be an absolute path.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = false;
      # A forced command is run as `<login shell> -c '<command>'`, so the push
      # user MUST have a usable shell. The default `nologin` for a system user
      # makes every push fail with a bare "This account is currently not
      # available." and no other clue. Giving a real shell is safe precisely
      # because ForceCommand replaces whatever the client asked for.
      shell = lib.mkDefault pkgs.bashInteractive;
      openssh.authorizedKeys.keys = map mkAuthorizedKey cfg.pushKeys;
    };

    users.groups.${cfg.group} = { };

    services.openssh.settings.AllowUsers = lib.mkIf cfg.manageAllowUsers (lib.mkDefault [ cfg.user ]);

    # mkOrder 2000 keeps this Match block at the END of sshd_config. Every
    # line after a Match belongs to that Match until the next one, so a block
    # emitted at the default order swallows any global directive another
    # module appends afterwards — and most keywords are not legal inside a
    # Match, so sshd then refuses to start at all.
    services.openssh.extraConfig = lib.mkOrder 2000 ''
      Match User ${cfg.user}
        AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
        ForceCommand ${forcedCommand}
        PermitTTY no
        PermitUserRC no
        DisableForwarding yes
    '';

    systemd.tmpfiles.settings."10-${cfg.name}" = {
      "${cfg.dataDir}".d = {
        inherit (cfg) user group;
        mode = "0755";
      };
      "${cfg.dataDir}/incoming".d = {
        inherit (cfg) user group;
        mode = "0755";
      };
      "${cfg.dataDir}/published".d = {
        inherit (cfg) user group;
        mode = "0755";
      };
      "${cfg.dataDir}/quarantine".d = {
        inherit (cfg) user group;
        mode = "0755";
      };
      "${cfg.dataDir}/work".d = {
        inherit (cfg) user group;
        mode = "0700";
      };
    };

    systemd.paths."${cfg.name}-watch" = {
      description = "Watch ${cfg.dataDir}/incoming for new drops";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathModified = "${cfg.dataDir}/incoming";
        TriggerLimitIntervalSec = cfg.triggerLimitIntervalSec;
        TriggerLimitBurst = cfg.triggerLimitBurst;
        Unit = "${cfg.name}-dispatch.service";
      };
    };

    systemd.services."${cfg.name}-dispatch" = {
      description = "Dispatch a drop-box worker per unprocessed drop";
      after = orderingDeps;
      requires = orderingDeps;
      environment = {
        DROPBOX_DATA_DIR = cfg.dataDir;
        DROPBOX_WORKER_UNIT = "${cfg.name}@";
        DROPBOX_MAX_ID_LEN = toString cfg.maxIdLength;
      };
      # A path unit that trips its triggered service's START rate limit fails
      # too, and then stops watching. systemd's defaults (5 starts per 10s)
      # are well inside the range a handful of near-simultaneous pushes
      # produces, so the limit is removed here rather than tuned.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe dispatchScript;
      }
      // controlHardening;
    };

    systemd.services."${cfg.name}@" = {
      description = "Promote drop %i into published/, or quarantine it";
      after = orderingDeps;
      requires = orderingDeps;
      environment = workerEnv;
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        # A worker blocks for up to doneTimeoutSec waiting for the sentinel;
        # give it room beyond that before systemd calls it hung.
        TimeoutStartSec = cfg.doneTimeoutSec + 60;
        ExecStart = ''${lib.getExe promoteScript} "%I"'';
      }
      // workerHardening;
    };

    systemd.services."${cfg.name}-sweep" = lib.mkIf (cfg.sweepInterval != null) {
      description = "Re-arm the drop-box watcher and rescan incoming/";
      after = orderingDeps;
      path = [ pkgs.systemd ];
      serviceConfig = { Type = "oneshot"; } // controlHardening;
      script = ''
        systemctl reset-failed ${cfg.name}-watch.path >/dev/null 2>&1 || true
        systemctl start ${cfg.name}-watch.path || true
        systemctl start ${cfg.name}-dispatch.service || true
      '';
    };

    systemd.timers."${cfg.name}-sweep" = lib.mkIf (cfg.sweepInterval != null) {
      description = "Periodic drop-box catch-up sweep";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.sweepInterval;
        AccuracySec = "30s";
        Unit = "${cfg.name}-sweep.service";
      };
    };

    environment.systemPackages = lib.optional cfg.installClient pushScript;
  };
}
