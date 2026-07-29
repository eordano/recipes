# microvm-ram-snapshot-clones
#
# Sub-second, per-project throwaway dev VMs. Boot a microvm guest once, freeze
# its live RAM to a compressed image (QMP `stop` + `migrate` to `exec:zstd`),
# then spawn clones by streaming that image back into a fresh QEMU via
# `-incoming exec:zstd -d`. Clones wake up already-booted.
#
# There is no block device at all: /nix/store is shared read-only over
# virtiofs (cache=always, so clones cost zero store duplication), and the
# project directory is bound read-write as the workspace (cache=auto), so
# edits inside the clone are edits on the host tree.
#
# Clone identity is *derived*, not assigned: md5(realpath project-dir) yields a
# stable VM name and SSH port, so the same directory always maps to the same
# clone. The base snapshot only rebuilds when the guest `toplevel` nix hash
# changes, so refresh is a cheap no-op most of the time.
#
# This is a generic NixOS module. Import it, point `guestSystem` at an
# evaluated microvm nixosSystem, set `guestUser`, and enable. See README.md.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.microvmClone;

  # The guest is an evaluated microvm nixosSystem. We reach into it for the
  # kernel, initrd and toplevel that QEMU boots directly (no bootloader).
  vmCfg = cfg.guestSystem.config;
  kernel = "${vmCfg.microvm.kernel.out}/${pkgs.linux.target}";
  initrd = vmCfg.microvm.initrdPath;
  toplevel = vmCfg.system.build.toplevel;
  mem = toString vmCfg.microvm.mem;
  vcpu = toString vmCfg.microvm.vcpu;
  kernelParams = lib.concatStringsSep " " vmCfg.boot.kernelParams;

  virtiofsd = "${pkgs.virtiofsd}/bin/virtiofsd";
  qemu = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64";
  zstd = "${pkgs.zstd}/bin/zstd";
  ssh = "${pkgs.openssh}/bin/ssh";

  guestUser = cfg.guestUser;
  workspace = cfg.guestWorkspace;

  sshOpts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ${cfg.sshExtraOpts}";

  # Agent forwarding is off by default: anything running in the guest (including
  # the untrusted build steps/agents this VM is meant to host) can use a
  # forwarded agent socket to authenticate as the caller. Opt in via
  # forwardAgent only when the guest is trusted.
  sshAgentOpt = lib.optionalString cfg.forwardAgent "-A";

  # Boot the microvm straight from kernel+initrd+toplevel. The memory backend is
  # a shared memfd, which is what makes the live-RAM migrate/restore cheap.
  commonQemuFlags = ''
    -M q35,accel=kvm:tcg \
    -m ${mem} \
    -smp ${vcpu} \
    -nodefaults -no-user-config -no-reboot -nographic \
    -cpu max \
    -kernel ${kernel} \
    -initrd ${initrd} \
    -append "earlyprintk=ttyS0 console=ttyS0 reboot=t panic=-1 ${kernelParams} init=${toplevel}/init" \
    -numa node,memdev=mem \
    -object memory-backend-memfd,id=mem,size=${mem}M,share=on'';

  # Minimal QMP client. Speaks the JSON line protocol to drive
  # stop/migrate/cont, which is how we freeze and thaw a running guest.
  qmpScript =
    pkgs.writers.writePython3 "microvm-clone-qmp"
      {
        flakeIgnore = [
          "E401"
          "E302"
          "E305"
          "E501"
          "W391"
        ];
      }
      ''
        import socket, json, sys, time

        class Conn:
            def __init__(self, sock):
                self.sock = sock
                self.buf = b""

            def recv_json(self):
                while b"\n" not in self.buf:
                    data = self.sock.recv(4096)
                    if not data:
                        raise ConnectionError("closed")
                    self.buf += data
                while True:
                    line, _, self.buf = self.buf.partition(b"\n")
                    line = line.strip()
                    if line:
                        return json.loads(line)
                    if b"\n" not in self.buf:
                        while b"\n" not in self.buf:
                            data = self.sock.recv(4096)
                            if not data:
                                raise ConnectionError("closed")
                            self.buf += data

            def send(self, cmd, **args):
                msg = {"execute": cmd}
                if args:
                    msg["arguments"] = args
                self.sock.sendall(json.dumps(msg).encode() + b"\n")
                while True:
                    r = self.recv_json()
                    if "event" not in r:
                        return r

        path = sys.argv[1]
        action = sys.argv[2]

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(30)
        sock.connect(path)
        conn = Conn(sock)
        conn.recv_json()
        conn.send("qmp_capabilities")

        if action == "snapshot":
            uri = sys.argv[3]
            conn.send("stop")
            for _ in range(60):
                r = conn.send("query-status")
                if r.get("return", {}).get("status") == "paused":
                    break
                time.sleep(0.1)
            conn.send("migrate", uri=uri)
            for _ in range(600):
                r = conn.send("query-migrate")
                st = r.get("return", {}).get("status", "")
                if st == "completed":
                    print("OK", file=sys.stderr)
                    break
                if st == "failed":
                    print(f"FAILED: {r}", file=sys.stderr)
                    sys.exit(1)
                time.sleep(1)
            else:
                print("TIMEOUT", file=sys.stderr)
                sys.exit(1)
            conn.send("quit")

        elif action == "resume":
            for i in range(120):
                r = conn.send("query-status")
                st = r.get("return", {}).get("status", "")
                print(f"status: {st}", file=sys.stderr)
                if st not in ("inmigrate", "none"):
                    break
                time.sleep(0.5)
            r = conn.send("cont")
            print(f"cont: {r}", file=sys.stderr)
            for _ in range(60):
                r = conn.send("query-status")
                st = r.get("return", {}).get("status", "")
                if st == "running":
                    print(f"after cont: {st}", file=sys.stderr)
                    break
                time.sleep(0.1)

        elif action == "pause":
            conn.send("stop")
            for _ in range(60):
                r = conn.send("query-status")
                if r.get("return", {}).get("status") == "paused":
                    print("paused", file=sys.stderr)
                    break
                time.sleep(0.1)

        elif action == "quit":
            conn.send("quit")

        sock.close()
      '';

  # Derive clone identity from the project path: same dir -> same name+port.
  # Note the port space is 800 wide, so distinct dirs *can* collide on a port.
  resolve = ''
    resolve_clone() {
      local project_dir="$(realpath "''${1:-$PWD}")"
      VM_HASH=$(echo "$project_dir" | md5sum | cut -c1-8)
      VM_NAME="devvm-''${VM_HASH}"
      CLONE_DIR="${cfg.clonesDir}/''${VM_NAME}"
      SSH_PORT=$((2200 + 16#''${VM_HASH:0:3} % 800))
      PROJECT_DIR="$project_dir"
    }

    clone_running() {
      [ -f "''${CLONE_DIR}/qemu.pid" ] && \
        kill -0 "$(cat "''${CLONE_DIR}/qemu.pid")" 2>/dev/null
    }
  '';

  vmCli = pkgs.writeShellScriptBin "vm" ''
    set -euo pipefail

    ${resolve}

    die()  { echo "error: $*" >&2; exit 1; }

    cmd_snapshot() {
      SNAPSHOT_DIR="${cfg.snapshotDir}"
      SNAPSHOT_FILE="$SNAPSHOT_DIR/snapshot.zst"
      BUILD_HASH="$SNAPSHOT_DIR/build-hash"
      CURRENT_HASH=$(${pkgs.nix}/bin/nix hash path ${toplevel} 2>/dev/null || echo "unknown")

      # The snapshot only rebuilds when the guest toplevel hash changes, so
      # this is a cheap no-op most of the time.
      if [ -f "$BUILD_HASH" ] && [ -f "$SNAPSHOT_FILE" ]; then
        if [ "$(cat "$BUILD_HASH")" = "$CURRENT_HASH" ]; then
          echo "Snapshot up to date"
          exit 0
        fi
      fi

      echo "Creating base RAM snapshot..." >&2
      mkdir -p "$SNAPSHOT_DIR"

      EMPTY_DIR=$(mktemp -d)
      trap 'rm -rf "$EMPTY_DIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

      # RO /nix/store share: cache=always, since the store is immutable.
      ${virtiofsd} \
        --socket-path="$SNAPSHOT_DIR/virtiofs-ro-store.sock" \
        --shared-dir=/nix/store \
        --cache=always >> "$SNAPSHOT_DIR/virtiofsd.log" 2>&1 &
      VFSD_STORE_PID=$!

      # Base image is captured with an empty workspace mount; clones bind the
      # real project dir over the same tag at spawn time.
      ${virtiofsd} \
        --socket-path="$SNAPSHOT_DIR/virtiofs-workspace.sock" \
        --shared-dir="$EMPTY_DIR" \
        --cache=never >> "$SNAPSHOT_DIR/virtiofsd.log" 2>&1 &
      VFSD_WORK_PID=$!

      SOCK_OK=0
      for _i in $(seq 1 100); do
        if ! kill -0 $VFSD_STORE_PID 2>/dev/null || ! kill -0 $VFSD_WORK_PID 2>/dev/null; then
          echo "virtiofsd died. Log:" >&2
          cat "$SNAPSHOT_DIR/virtiofsd.log" >&2
          exit 1
        fi
        if [ -S "$SNAPSHOT_DIR/virtiofs-ro-store.sock" ] && \
           [ -S "$SNAPSHOT_DIR/virtiofs-workspace.sock" ]; then
          SOCK_OK=1
          break
        fi
        sleep 0.2
      done
      [ "$SOCK_OK" -eq 1 ] || { echo "virtiofsd sockets timeout" >&2; exit 1; }

      echo "Booting base VM..." >&2
      nohup ${qemu} \
        -name devvm-snapshot \
        ${commonQemuFlags} \
        -serial file:"$SNAPSHOT_DIR/console.log" \
        -chardev socket,id=fs-ro-store,path="$SNAPSHOT_DIR/virtiofs-ro-store.sock" \
        -device vhost-user-fs-pci,chardev=fs-ro-store,tag=ro-store \
        -chardev socket,id=fs-workspace,path="$SNAPSHOT_DIR/virtiofs-workspace.sock" \
        -device vhost-user-fs-pci,chardev=fs-workspace,tag=workspace \
        -netdev user,id=net0,hostfwd=tcp::2299-:22 \
        -device virtio-net-pci,netdev=net0,mac=02:00:00:ff:ff:ff \
        -qmp unix:"$SNAPSHOT_DIR/qmp.sock",server,nowait \
        > /dev/null 2>&1 &
      echo $! > "$SNAPSHOT_DIR/qemu.pid"

      for _i in $(seq 1 60); do
        [ -S "$SNAPSHOT_DIR/qmp.sock" ] && break
        if ! kill -0 "$(cat "$SNAPSHOT_DIR/qemu.pid")" 2>/dev/null; then
          echo "QEMU failed to start" >&2; exit 1
        fi
        sleep 0.2
      done

      # The guest must signal readiness by touching .boot-ready in the
      # workspace mount (see README for the guest-side one-liner).
      echo "Waiting for boot..." >&2
      BOOT_OK=0
      for _i in $(seq 1 900); do
        if [ -f "$SNAPSHOT_DIR/qemu.pid" ] && ! kill -0 "$(cat "$SNAPSHOT_DIR/qemu.pid")" 2>/dev/null; then
          echo "QEMU died during boot" >&2
          tail -n 20 "$SNAPSHOT_DIR/console.log" >&2 2>/dev/null || true
          exit 1
        fi
        if [ -f "$EMPTY_DIR/.boot-ready" ]; then
          BOOT_OK=1
          break
        fi
        sleep 1
      done
      [ "$BOOT_OK" -eq 1 ] || { echo "Boot timeout" >&2; tail -n 40 "$SNAPSHOT_DIR/console.log" >&2 2>/dev/null; exit 1; }

      # Freeze the CPU, then dump live RAM through zstd to the snapshot file.
      echo "Saving RAM snapshot..." >&2
      rm -f "$SNAPSHOT_FILE"
      ${qmpScript} "$SNAPSHOT_DIR/qmp.sock" snapshot "exec:${zstd} -T0 -3 -o $SNAPSHOT_FILE"

      if [ -f "$SNAPSHOT_DIR/qemu.pid" ]; then
        for _i in $(seq 1 30); do
          kill -0 "$(cat "$SNAPSHOT_DIR/qemu.pid")" 2>/dev/null || break
          sleep 0.2
        done
      fi
      rm -f "$SNAPSHOT_DIR"/*.sock "$SNAPSHOT_DIR"/qmp.sock "$SNAPSHOT_DIR"/qemu.pid

      echo "$CURRENT_HASH" > "$BUILD_HASH"
      echo "Snapshot ready: $(du -h "$SNAPSHOT_FILE" | cut -f1)" >&2
    }

    cmd_spawn() {
      ${cfg.sshKeySetup}

      NO_ENTER=0
      ARGS=()
      for arg in "$@"; do
        case "$arg" in
          --no-enter) NO_ENTER=1 ;;
          *) ARGS+=("$arg") ;;
        esac
      done

      resolve_clone "''${ARGS[0]:-}"

      if clone_running; then
        if [ "$NO_ENTER" -eq 1 ]; then
          echo "''${SSH_PORT}"
        else
          exec ${ssh} -t ${sshAgentOpt} ${sshOpts} ${cfg.sshEnterOpts} -p "''${SSH_PORT}" ${guestUser}@localhost "cd ${workspace}; exec \$SHELL -l"
        fi
        exit 0
      fi

      local RESTORING=0
      local SNAPSHOT_FILE
      if [ -f "''${CLONE_DIR}/save.zst" ]; then
        SNAPSHOT_FILE="''${CLONE_DIR}/save.zst"
        RESTORING=1
        echo "Restoring: $(cat "''${CLONE_DIR}/save.desc" 2>/dev/null)" >&2
      else
        SNAPSHOT_FILE="${cfg.snapshotDir}/snapshot.zst"
        [ -f "$SNAPSHOT_FILE" ] || die "No snapshot found. Run: sudo vm update"
        echo "Spawning clone for $(basename "$PROJECT_DIR")..." >&2
      fi

      mkdir -p "''${CLONE_DIR}"
      rm -f "''${CLONE_DIR}"/*.sock "''${CLONE_DIR}"/*.pid

      # Same RO store share as the base image (cache=always, zero duplication).
      ${virtiofsd} \
        --socket-path="''${CLONE_DIR}/virtiofs-ro-store.sock" \
        --shared-dir=/nix/store \
        --cache=always > "''${CLONE_DIR}/virtiofsd.log" 2>&1 &
      echo $! > "''${CLONE_DIR}/virtiofsd-ro-store.pid"

      # Bind the real project dir RW as the workspace (cache=auto): edits in
      # the clone land on the host tree.
      ${virtiofsd} \
        --socket-path="''${CLONE_DIR}/virtiofs-workspace.sock" \
        --shared-dir="''${PROJECT_DIR}" \
        --cache=auto >> "''${CLONE_DIR}/virtiofsd.log" 2>&1 &
      echo $! > "''${CLONE_DIR}/virtiofsd-workspace.pid"

      for _i in $(seq 1 100); do
        [ -S "''${CLONE_DIR}/virtiofs-ro-store.sock" ] && \
        [ -S "''${CLONE_DIR}/virtiofs-workspace.sock" ] && break
        for pidfile in "''${CLONE_DIR}"/virtiofsd-*.pid; do
          [ -f "$pidfile" ] && ! kill -0 "$(cat "$pidfile")" 2>/dev/null && \
            { echo "virtiofsd failed to start (see ''${CLONE_DIR}/virtiofsd.log)" >&2; exit 1; }
        done
        sleep 0.2
      done

      # Restore: stream the frozen RAM back in. The guest wakes already-booted.
      printf "  Restoring from snapshot..." >&2
      nohup ${qemu} \
        -name "''${VM_NAME}" \
        ${commonQemuFlags} \
        -serial file:"''${CLONE_DIR}/console.log" \
        -chardev socket,id=fs-ro-store,path="''${CLONE_DIR}/virtiofs-ro-store.sock" \
        -device vhost-user-fs-pci,chardev=fs-ro-store,tag=ro-store \
        -chardev socket,id=fs-workspace,path="''${CLONE_DIR}/virtiofs-workspace.sock" \
        -device vhost-user-fs-pci,chardev=fs-workspace,tag=workspace \
        -netdev user,id=net0,hostfwd=tcp::''${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=net0,mac=02:00:00:00:00:10 \
        -qmp unix:"''${CLONE_DIR}/qmp.sock",server,nowait \
        -incoming "exec:${zstd} -d -c $SNAPSHOT_FILE" \
        > /dev/null 2>&1 &
      echo $! > "''${CLONE_DIR}/qemu.pid"

      for _i in $(seq 1 120); do
        [ -S "''${CLONE_DIR}/qmp.sock" ] && break
        sleep 0.5
      done

      ${qmpScript} "''${CLONE_DIR}/qmp.sock" resume 2>/dev/null
      printf " done\n" >&2

      printf "  Waiting for SSH..." >&2
      SSH_OK=0
      for _i in $(seq 1 60); do
        if ${ssh} -q ${sshOpts} -o ConnectTimeout=1 -p "''${SSH_PORT}" ${guestUser}@localhost true 2>/dev/null; then
          SSH_OK=1
          break
        fi
        if ! kill -0 "$(cat "''${CLONE_DIR}/qemu.pid" 2>/dev/null)" 2>/dev/null; then
          printf " failed\n" >&2
          echo "QEMU died during restore (see ''${CLONE_DIR}/console.log)" >&2
          exit 1
        fi
        sleep 0.5
      done
      if [ "$SSH_OK" -ne 1 ]; then
        printf " failed\n" >&2
        echo "SSH timeout on port ''${SSH_PORT}" >&2
        exit 1
      fi
      printf " done\n" >&2

      if [ "$RESTORING" -eq 1 ]; then
        rm -f "''${CLONE_DIR}/save.zst" "''${CLONE_DIR}/save.desc" "''${CLONE_DIR}/save.date"
      fi

      if [ "$NO_ENTER" -eq 1 ]; then
        echo "''${SSH_PORT}"
      else
        exec ${ssh} -t ${sshAgentOpt} ${sshOpts} ${cfg.sshEnterOpts} -p "''${SSH_PORT}" ${guestUser}@localhost "cd ${workspace}; exec \$SHELL -l"
      fi
    }

    cmd_save() {
      local desc="$*"
      if [ ''${#desc} -le 20 ]; then
        die "Description required (>20 chars): vm save <what you're working on>"
      fi

      resolve_clone
      clone_running || die "No running clone for $PROJECT_DIR"

      echo "$PROJECT_DIR" > "''${CLONE_DIR}/project_dir"
      echo "$desc" > "''${CLONE_DIR}/save.desc"
      echo "$(date -Iseconds)" > "''${CLONE_DIR}/save.date"

      printf "Saving VM state..." >&2
      ${qmpScript} "''${CLONE_DIR}/qmp.sock" snapshot "exec:${zstd} -T0 -3 -o ''${CLONE_DIR}/save.zst"

      if [ -f "''${CLONE_DIR}/qemu.pid" ]; then
        for _i in $(seq 1 30); do
          kill -0 "$(cat "''${CLONE_DIR}/qemu.pid")" 2>/dev/null || break
          sleep 0.2
        done
      fi
      for pidfile in "''${CLONE_DIR}"/*.pid; do
        [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
      done
      rm -f "''${CLONE_DIR}"/*.sock "''${CLONE_DIR}"/qmp.sock "''${CLONE_DIR}"/qemu.pid "''${CLONE_DIR}"/*.pid

      printf " done\n" >&2
      echo "Saved: $desc" >&2
    }

    cmd_stop() {
      resolve_clone "''${1:-}"

      [ -d "''${CLONE_DIR}" ] || exit 0

      if [ -S "''${CLONE_DIR}/qmp.sock" ]; then
        ${qmpScript} "''${CLONE_DIR}/qmp.sock" quit 2>/dev/null || true
        if [ -f "''${CLONE_DIR}/qemu.pid" ]; then
          for _i in $(seq 1 30); do
            kill -0 "$(cat "''${CLONE_DIR}/qemu.pid")" 2>/dev/null || break
            sleep 0.2
          done
        fi
      fi

      for pidfile in "''${CLONE_DIR}"/*.pid; do
        [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
      done
      rm -rf "''${CLONE_DIR}"
      echo "Stopped ''${VM_NAME}" >&2
    }

    cmd_list() {
      printf "%-12s %-8s %-6s %s\n" "CLONE" "STATUS" "PORT" "INFO"
      for dir in ${cfg.clonesDir}/devvm-*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        hash=''${name#devvm-}
        port=$((2200 + 16#''${hash:0:3} % 800))
        pid_file="$dir/qemu.pid"
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
          printf "%-12s %-8s %-6s %s\n" "$name" "running" "$port" "pid $(cat "$pid_file")"
        elif [ -f "$dir/save.zst" ]; then
          printf "%-12s %-8s %-6s %s\n" "$name" "saved" "$port" "$(cat "$dir/save.desc" 2>/dev/null)"
        else
          printf "%-12s %-8s %-6s %s\n" "$name" "dead" "$port" "-"
        fi
      done
    }

    cmd_status() {
      resolve_clone "''${1:-}"
      echo "Project: $PROJECT_DIR"
      echo "Clone:   $VM_NAME"
      echo "Port:    $SSH_PORT"
      if clone_running; then
        echo "Status:  running (pid $(cat "''${CLONE_DIR}/qemu.pid"))"
      elif [ -f "''${CLONE_DIR}/save.zst" ]; then
        echo "Status:  saved"
        echo "Desc:    $(cat "''${CLONE_DIR}/save.desc" 2>/dev/null)"
        echo "Date:    $(cat "''${CLONE_DIR}/save.date" 2>/dev/null)"
      elif [ -d "''${CLONE_DIR}" ]; then
        echo "Status:  dead"
      else
        echo "Status:  not created"
      fi

      local snap="${cfg.snapshotDir}/snapshot.zst"
      if [ -f "$snap" ]; then
        echo "Snapshot: $(du -h "$snap" | cut -f1)"
      else
        echo "Snapshot: none"
      fi
    }

    cmd_root_enter() {
      ${cfg.sshKeySetup}
      resolve_clone "''${1:-}"
      clone_running || die "Clone not running for $PROJECT_DIR"
      exec ${ssh} -t ${sshAgentOpt} ${sshOpts} ${cfg.sshEnterOpts} -p "''${SSH_PORT}" root@localhost
    }

    cmd_logs() {
      ${cfg.sshKeySetup}
      resolve_clone "''${1:-}"
      clone_running || die "Clone not running for $PROJECT_DIR"
      exec ${ssh} ${sshOpts} -p "''${SSH_PORT}" root@localhost journalctl -f
    }

    cmd_pause() {
      resolve_clone "''${1:-}"
      clone_running || die "Clone not running for $PROJECT_DIR"
      ${qmpScript} "''${CLONE_DIR}/qmp.sock" pause
      echo "Paused ''${VM_NAME}" >&2
    }

    cmd_resume() {
      resolve_clone "''${1:-}"
      clone_running || die "Clone not running for $PROJECT_DIR"
      ${qmpScript} "''${CLONE_DIR}/qmp.sock" resume
      echo "Resumed ''${VM_NAME}" >&2
    }

    cmd_completions() {
      local shell="''${1:?Usage: vm completions <bash|zsh|fish>}"
      case "$shell" in
        bash)
          cat <<'BASH_COMP'
    _vm() {
      local cur prev cmds
      COMPREPLY=()
      cur="''${COMP_WORDS[COMP_CWORD]}"
      prev="''${COMP_WORDS[COMP_CWORD-1]}"
      cmds="spawn enter init start save restore stop list status root-enter logs pause resume update help"

      if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
        COMPREPLY+=($(compgen -d -- "$cur"))
        return
      fi

      case "$prev" in
        spawn|enter|init|start|restore|stop|status|root-enter|logs|pause|resume)
          COMPREPLY=($(compgen -d -- "$cur"))
          ;;
        completions)
          COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
          ;;
      esac
    }
    complete -o filenames -F _vm vm
    BASH_COMP
          ;;
        zsh)
          cat <<'ZSH_COMP'

    _vm() {
      local -a commands=(
        'spawn:Spawn clone and enter'
        'enter:Spawn clone and enter'
        'init:Spawn clone and enter'
        'start:Spawn clone and enter'
        'save:Hibernate clone to disk'
        'restore:Restore a saved clone'
        'stop:Stop and remove clone'
        'list:List all clones'
        'status:Detailed status of a clone'
        'root-enter:SSH as root'
        'logs:Stream journalctl from clone'
        'pause:Pause clone CPU'
        'resume:Resume paused clone'
        'update:Create/refresh base RAM snapshot'
        'completions:Output shell completions'
        'help:Show help'
      )

      if (( CURRENT == 2 )); then
        _describe 'command' commands
        _directories
        return
      fi

      case "''${words[2]}" in
        spawn|enter|init|start|restore|stop|status|root-enter|logs|pause|resume)
          _directories
          ;;
        completions)
          _values 'shell' bash zsh fish
          ;;
      esac
    }

    _vm "$@"
    ZSH_COMP
          ;;
        fish)
          cat <<'FISH_COMP'
    set -l commands spawn enter init start save restore stop list status root-enter logs pause resume update completions help
    set -l dir_cmds spawn enter init start restore stop status root-enter logs pause resume

    complete -c vm -f
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a spawn -d 'Spawn clone and enter'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a enter -d 'Enter clone'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a save -d 'Hibernate clone to disk'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a restore -d 'Restore saved clone'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a stop -d 'Stop clone'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a list -d 'List all clones'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a status -d 'Clone status'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a root-enter -d 'SSH as root'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a logs -d 'Stream logs'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a pause -d 'Pause clone'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a resume -d 'Resume clone'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a update -d 'Refresh base snapshot'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a help -d 'Show help'
    complete -c vm -n "not __fish_seen_subcommand_from $commands" -a "(__fish_complete_directories)"

    complete -c vm -n "__fish_seen_subcommand_from $dir_cmds" -a "(__fish_complete_directories)"
    complete -c vm -n "__fish_seen_subcommand_from completions" -a "bash zsh fish"
    FISH_COMP
          ;;
        *)
          die "Unknown shell: $shell (use bash, zsh, or fish)"
          ;;
      esac
    }

    cmd_help() {
      cat <<'HELP'
    vm - NixOS dev VM manager (RAM snapshot/clone)

    Usage: vm [command] [dir]

    Commands:
      (none)              Spawn or enter clone for current directory
      spawn [dir]         Spawn clone and enter (aliases: enter, init, start)
      save <description>  Hibernate clone to disk (description >20 chars required)
      restore [dir]       Restore a saved clone (also happens automatically via spawn)
      stop [dir]          Stop and remove clone
      list                List all clones (running, saved, dead)
      status [dir]        Detailed status of a clone
      root-enter [dir]    SSH as root
      logs [dir]          Stream journalctl from clone
      pause [dir]         Pause clone CPU
      resume [dir]        Resume paused clone
      update              Create/refresh base RAM snapshot (requires sudo)
      completions <shell> Output shell completions (bash|zsh|fish)
      help                Show this help

    If [dir] is omitted, the current directory is used.
    HELP
    }

    cmd="''${1:-spawn}"
    shift || true

    case "$cmd" in
      spawn|enter|init|start) cmd_spawn "$@" ;;
      save)                   cmd_save "$@" ;;
      restore)
        resolve_clone "''${1:-}"
        [ -f "''${CLONE_DIR}/save.zst" ] || die "No saved state. Use 'vm save' first."
        cmd_spawn "$@"
        ;;
      stop)                   cmd_stop "$@" ;;
      list|ls)                cmd_list ;;
      status)                 cmd_status "$@" ;;
      root-enter)             cmd_root_enter "$@" ;;
      logs)                   cmd_logs "$@" ;;
      pause)                  cmd_pause "$@" ;;
      resume)                 cmd_resume "$@" ;;
      update|snapshot)        cmd_snapshot ;;
      completions)            cmd_completions "$@" ;;
      help|--help|-h)         cmd_help ;;
      *)
        if [ -d "$cmd" ]; then
          cmd_spawn "$cmd" "$@"
        else
          die "Unknown command: $cmd (try 'vm help')"
        fi
        ;;
    esac
  '';

in
{
  options.modules.microvmClone = {
    enable = lib.mkEnableOption "per-project RAM-snapshot microvm clones";

    guestSystem = lib.mkOption {
      type = lib.types.unspecified;
      description = ''
        Evaluated nixosSystem for the guest VM. Must include
        `microvm.nixosModules.microvm` and configure an sshd the host can reach
        over the forwarded port. See README.md for a minimal example guest.
      '';
    };

    guestUser = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Unprivileged user to SSH into inside the guest (must exist in the guest system).";
    };

    guestWorkspace = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.guestUser}/workspace";
      description = "Path inside the guest where the project dir (virtiofs workspace tag) is mounted; interactive sessions cd here.";
    };

    snapshotDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvm-clone-snapshot";
      description = "Persistent directory holding the base RAM snapshot.";
    };

    clonesDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/microvm-clones";
      description = "Per-clone runtime state. Default under /run (tmpfs), so clones are disposable and vanish on reboot.";
    };

    snapshotAtBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Auto-create the base snapshot at boot via a systemd oneshot.";
    };

    direnv = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install a direnv `layout_devvm` that auto-spawns a clone on directory entry and drops vm/vm-run/vm-stop shims into .direnv/bin.";
    };

    sshExtraOpts = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Extra SSH options appended to all ssh commands (e.g., -i keypath for testing).";
    };

    sshKeySetup = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell commands run before SSH connections (e.g., copy a private key out of the nix store into a mode-0600 tempfile and add it to sshExtraOpts).";
    };

    sshEnterOpts = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Extra SSH options for interactive sessions only (e.g., GPG forwarding).";
    };

    forwardAgent = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Forward the caller's ssh-agent (`ssh -A`) into interactive clone
        sessions and the direnv shims. Off by default: anything running in the
        guest — including the untrusted build steps or agents this VM is meant
        to host — can use a forwarded agent socket to authenticate as you to any
        host your keys reach, without ever seeing the key material. Only enable
        when the code running inside the guest is trusted.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ vmCli ];

        environment.etc."bash_completion.d/vm".source = pkgs.runCommand "vm-bash-comp" { } ''
          ${vmCli}/bin/vm completions bash > $out
        '';
        environment.etc."fish/vendor_completions.d/vm.fish".source = pkgs.runCommand "vm-fish-comp" { } ''
          ${vmCli}/bin/vm completions fish > $out
        '';
        environment.etc."zsh/site-functions/_vm".source = pkgs.runCommand "vm-zsh-comp" { } ''
          ${vmCli}/bin/vm completions zsh > $out
        '';

        systemd.services.microvm-clone-snapshot = lib.mkIf cfg.snapshotAtBoot {
          description = "Create base RAM snapshot for microvm clone spawning";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${vmCli}/bin/vm update";
            TimeoutStartSec = "300";
          };
        };

        # clonesDir is a shared runtime dir the vm CLI writes pid/socket/state
        # files into. Sticky bit (1777) so any local user can create their own
        # clone state but cannot rename or delete another user's — without the
        # sticky bit, since clone identity is a predictable md5(project-dir), a
        # local attacker could pre-create or clobber a victim's CLONE_DIR (plant
        # a pidfile to make `vm stop`/`vm list` kill an arbitrary PID, or symlink
        # the dir elsewhere). On a single-user workstation 0755 is also fine; set
        # clonesDir per-user (e.g. under /run/user/$UID) to isolate fully.
        systemd.tmpfiles.rules = [
          "d ${cfg.snapshotDir} 0755 root root - -"
          "d ${cfg.clonesDir}   1777 root root - -"
        ];
      }

      (lib.mkIf cfg.direnv {
        environment.etc."devvm-direnv-layout.sh" = {
          text = ''
            layout_devvm() {
              local project_dir="$PWD"
              local port

              port=$(vm spawn --no-enter "$project_dir" 2>/dev/null | tail -1)

              if [ -z "$port" ]; then
                log_error "vm spawn failed for $project_dir"
                return 1
              fi

              export DEVVM_PORT="$port"
              export DEVVM_NAME="devvm-$(echo "$project_dir" | md5sum | cut -c1-8)"
              export DEVVM_PROJECT="$project_dir"

              local bin_dir
              bin_dir="$(direnv_layout_dir)/bin"
              PATH_add "$bin_dir"
              mkdir -p "$bin_dir"

              cat > "$bin_dir/vm" <<VMSCRIPT
            #!/usr/bin/env bash
            exec ssh -t ${sshAgentOpt} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR \
                 ${cfg.sshEnterOpts} \
                 -p $port ${guestUser}@localhost \
                 "cd ${workspace}; \''${*:-\$SHELL}"
            VMSCRIPT
              chmod +x "$bin_dir/vm"

              cat > "$bin_dir/vm-run" <<VMSCRIPT
            #!/usr/bin/env bash
            exec ssh ${sshAgentOpt} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR \
                 ${cfg.sshEnterOpts} \
                 -p $port ${guestUser}@localhost \
                 "cd ${workspace}; \$*"
            VMSCRIPT
              chmod +x "$bin_dir/vm-run"

              cat > "$bin_dir/vm-stop" <<VMSCRIPT
            #!/usr/bin/env bash
            exec vm stop "$project_dir"
            VMSCRIPT
              chmod +x "$bin_dir/vm-stop"

              log_status "devvm clone ready (port $port) — type 'vm' to enter"
            }
          '';
        };
        # Runs as root at every activation over user-owned homes. Treat the
        # per-home path as hostile: derive the owner from the directory itself
        # (not basename), refuse to traverse any user-planted symlink in the
        # .config/direnv/lib chain, and never `chown -R` a user-controlled root
        # — only create real dirs and chown the single symlink we own.
        system.activationScripts.devvm-direnv-link = ''
          for home in /home/*/; do
            home="''${home%/}"
            [ -d "$home" ] || continue
            [ -L "$home" ] && continue
            user="$(stat -c %U "$home" 2>/dev/null)" || continue
            case "$user" in "" | UNKNOWN | root) continue ;; esac

            # Bail out if any component is a symlink or a non-directory, so root
            # never follows a symlink out of the user's home.
            ok=1
            dir="$home"
            for part in .config direnv lib; do
              dir="$dir/$part"
              if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
                ok=0
                break
              fi
            done
            [ "$ok" = 1 ] || continue

            install -d -o "$user" -m 0755 "$home/.config/direnv/lib" 2>/dev/null || continue
            ln -sfn /etc/devvm-direnv-layout.sh "$home/.config/direnv/lib/devvm.sh"
            chown -h "$user" "$home/.config/direnv/lib/devvm.sh" 2>/dev/null || true
          done
        '';
      })
    ]
  );
}
