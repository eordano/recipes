# NixOS VM test for the ssh-write-only-drop-box module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from a flake:
#
#   pkgs.callPackage ./modules/ssh-write-only-drop-box/test.nix { }
#
# The module's security claim is a PAIRING: a forced command in every
# authorized_keys line AND a `Match User` block that sets `ForceCommand` and
# narrows `AuthorizedKeysFile`. Half of that is not a weaker version of the
# whole, it is no enforcement at all — so this test carries a NEGATIVE CONTROL
# node, `unpaired`: the half implementation, carrying the module's own
# `command="…",restrict` lines (lifted from a real evaluation of the recipe)
# and no `Match` block. Every "the paired server refuses X" assertion is
# followed by "and the unpaired one does X", which is what makes the first
# assertion non-vacuous: a test that only says "ssh failed" is equally
# satisfied by a typo in a hostname.
#
# What it proves:
#
#    1. topology sanity — no framework-assigned 192.168.* addresses anywhere,
#       one address per topology interface (see lib/nixos-test-topology).
#    2. a client holding a push key CAN rsync a directory in, and the drop is
#       PROMOTED into published/ once its sentinel lands.
#    3. that same client cannot LIST the drop-box.
#    4. …cannot READ anything back (rsync pull, and scp of an absolute path).
#    5. …cannot OVERWRITE a file it already wrote (allowOverwrite = false:
#       the push reports success and changes nothing).
#    6. …cannot DELETE (allowDelete = false).
#    7. …cannot run an arbitrary command, and cannot get an interactive shell.
#    8. PAIRING: an unrestricted key that reaches the managed authorized_keys
#       file — no `command=`, no `restrict` — still gets no command and no
#       forwarding, because `ForceCommand` overrides `command=` and
#       `DisableForwarding` overrides the missing `restrict`. The same key on
#       `unpaired` gets a full shell and a working TCP forward.
#    9. PAIRING: a key planted in the push user's own
#       `~/.ssh/authorized_keys` does not authenticate at all, because the
#       `Match` block narrows `AuthorizedKeysFile`. The same planted key
#       authenticates on `unpaired`.
#   10. PAIRING: the `Match` block is emitted LAST in sshd_config (mkOrder
#       2000), so it cannot swallow a global directive appended after it.
#   11. the rsync "no atomic done signal" trap: a drop whose sentinel never
#       arrives is never promoted, and is QUARANTINED with a machine-readable
#       reason once the deadline passes.
#   12. a malicious drop id is REJECTED rather than used as a path component:
#         a. `..` in the remote path is refused by the transport;
#         b. an absolute remote path is confined to the chroot, not honoured;
#         c. a leading-dot id is quarantined under a digest of its name;
#         d. a hand-started worker with `/` or a leading dot in its instance
#            name touches nothing at all.
{ pkgs, ... }:
let
  inherit (pkgs) lib;

  topo = (import ../../lib/nixos-test-topology).mkTopology {
    subnets.lan.vlan = 1;
    hosts = {
      client.addresses.lan = 10;
      server.addresses.lan = 20;
      unpaired.addresses.lan = 30;
    };
  };

  dataDir = "/srv/artifacts";
  pushUser = "dropbox";
  doneTimeout = 60;

  # Throwaway keypairs generated for this test and nothing else. They are
  # public the moment this file is. Never reuse them for anything.
  keys = {
    # Legitimate CI push key: listed in `pushKeys`, so the module writes it
    # with `command="…",restrict`.
    push = {
      public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFmGRl5D+bPVGyWXbwT3ZJyjc2uOcqpRZrxRo7FsVZ6H drop-box-test-push";
      private = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACBZhkZeQ/mz1Rsll28E92Sco3NrjnKqUWa8UaOxbFWehwAAAJi3rArbt6wK
        2wAAAAtzc2gtZWQyNTUxOQAAACBZhkZeQ/mz1Rsll28E92Sco3NrjnKqUWa8UaOxbFWehw
        AAAEC1U/54Pb2J4c/SdCjuReNcQGcVDWDmz8tHa6HWALnu5lmGRl5D+bPVGyWXbwT3ZJyj
        c2uOcqpRZrxRo7FsVZ6HAAAAEmRyb3AtYm94LXRlc3QtcHVzaAECAw==
        -----END OPENSSH PRIVATE KEY-----
      '';
    };
    # An unrestricted key that reaches the SAME managed file the module writes
    # — the shape a second module, an admin, or a compromised deploy leaves
    # behind. It has no `command=` and no `restrict`, so on its own it is a
    # shell. Only the `Match` block stops it.
    attacker = {
      public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILnMTAmncy0sgtf198qU/nAwPmQ1TbiwGnezWzMxdNKI drop-box-test-attacker";
      private = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACC5zEwJp3MtLILX9ffKlP5wMD5kNU24sBp3s1szMXTSiAAAAKCK1KcmitSn
        JgAAAAtzc2gtZWQyNTUxOQAAACC5zEwJp3MtLILX9ffKlP5wMD5kNU24sBp3s1szMXTSiA
        AAAECmMgg40IkLuwRGEQ5qHCB9GbXSupVIvdTJqt0wO4CyB7nMTAmncy0sgtf198qU/nAw
        PmQ1TbiwGnezWzMxdNKIAAAAFmRyb3AtYm94LXRlc3QtYXR0YWNrZXIBAgMEBQYH
        -----END OPENSSH PRIVATE KEY-----
      '';
    };
    # Planted at runtime into the push user's own ~/.ssh/authorized_keys,
    # which is inside dataDir and therefore writable by anything that already
    # got a foothold as that user.
    planted = {
      public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAK8cxbx+3bvBng4oog+Yaev2Ig9N7la/+TIxwTd4jbB drop-box-test-planted";
      private = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACACvHMW8ft27wZ4OKKIPmGnr9iIPTe5Wv/kyMcE3eI2wQAAAJgJuuLACbri
        wAAAAAtzc2gtZWQyNTUxOQAAACACvHMW8ft27wZ4OKKIPmGnr9iIPTe5Wv/kyMcE3eI2wQ
        AAAEBy69YwOSc0xF7CHvnQ5NwW0UShczF9Wdpxqq/RRTMAIwK8cxbx+3bvBng4oog+Yaev
        2Ig9N7la/+TIxwTd4jbBAAAAFWRyb3AtYm94LXRlc3QtcGxhbnRlZA==
        -----END OPENSSH PRIVATE KEY-----
      '';
    };
  };

  dropBoxSettings = {
    enable = true;
    inherit dataDir;
    user = pushUser;
    group = pushUser;
    doneTimeoutSec = doneTimeout;
    allowOverwrite = false;
    allowDelete = false;
    pushKeys = [ keys.push.public ];
  };

  receiver = {
    imports = [ ./default.nix ];
    services.openssh.enable = true;
    # Pinned, not defaulted. Subtest 9 is only meaningful if the GLOBAL
    # AuthorizedKeysFile would otherwise read the push user's home — that is
    # nixpkgs' default today (sshd.nix: `authorizedKeysInHomedir` default
    # true), and if it ever flips the subtest would silently start proving
    # nothing. The runtime assertion re-checks it in the generated config.
    services.openssh.authorizedKeysInHomedir = true;
    services.sshDropBox = dropBoxSettings;
    users.users.${pushUser}.openssh.authorizedKeys.keys = [ keys.attacker.public ];
    networking.firewall.enable = false;
    system.stateVersion = "25.05";
  };

  # A plain, non-VM evaluation of the recipe, used only to lift the module's
  # OWN generated authorized_keys lines into the negative-control node. Taking
  # them from a real evaluation rather than re-typing them is what keeps the
  # control honest: the control differs from `server` in exactly one thing,
  # the absence of the `Match` block.
  recipeEval =
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ./default.nix
        {
          boot.loader.grub.enable = false;
          system.stateVersion = "25.05";
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          services.openssh.enable = true;
          services.sshDropBox = dropBoxSettings;
        }
      ];
    }).config;

  forcedKeyLines = recipeEval.users.users.${pushUser}.openssh.authorizedKeys.keys;

  forcedKeyLinesOk =
    forcedKeyLines != [ ]
    && builtins.all (l: lib.hasPrefix ''command="'' l && lib.hasInfix ''",restrict '' l) forcedKeyLines;
in
assert lib.assertMsg forcedKeyLinesOk ''
  services.sshDropBox no longer writes `command="…",restrict` into
  authorized_keys. Got: ${lib.generators.toPretty { } forcedKeyLines}
'';
pkgs.testers.runNixOSTest {
  name = "ssh-write-only-drop-box";

  nodes = {
    client =
      { config, pkgs, ... }:
      {
        imports = [
          topo.nodes.client
          ./default.nix
        ];
        networking.firewall.enable = false;
        system.stateVersion = "25.05";

        # The client half of the recipe, taken straight off the module's
        # read-only `clientPackage` option — the drop-box itself is not
        # enabled here, this host only pushes.
        environment.systemPackages = [
          config.services.sshDropBox.clientPackage
          pkgs.rsync
          pkgs.openssh
        ];

        environment.etc = {
          "drop-box-test/push".text = keys.push.private;
          "drop-box-test/attacker".text = keys.attacker.private;
          "drop-box-test/planted".text = keys.planted.private;
        };
      };

    # The module as an adopter deploys it: forced command AND Match block.
    server = { ... }: {
      imports = [
        topo.nodes.server
        receiver
      ];
    };

    # NEGATIVE CONTROL — the HALF IMPLEMENTATION. Same push user, same shell,
    # the module's own `command="…",restrict` lines, the same extra
    # unrestricted key — and no `Match` block. Nothing here should ever be
    # deployed; it exists so the paired node's refusals can be attributed to
    # the pairing rather than to an unrelated failure.
    #
    # It deliberately does NOT import the recipe. `lib.mkForce ""` on
    # `services.openssh.extraConfig` looks like the way to strip just the
    # Match block, and is not: nixpkgs emits `AuthorizedKeysFile`, `HostKey`,
    # `Port` and `Subsystem sftp` through that same option at `mkOrder 0`
    # (sshd.nix), so forcing it empty breaks authentication outright and the
    # control would "prove" the bypass is impossible for entirely the wrong
    # reason.
    unpaired =
      { pkgs, ... }:
      {
        imports = [ topo.nodes.unpaired ];
        networking.firewall.enable = false;
        system.stateVersion = "25.05";

        services.openssh.enable = true;
        services.openssh.authorizedKeysInHomedir = true;

        users.groups.${pushUser} = { };
        users.users.${pushUser} = {
          isSystemUser = true;
          group = pushUser;
          home = dataDir;
          createHome = false;
          shell = pkgs.bashInteractive;
          openssh.authorizedKeys.keys = forcedKeyLines ++ [ keys.attacker.public ];
        };

        systemd.tmpfiles.settings."10-drop-box-control" = {
          "${dataDir}".d = {
            user = pushUser;
            group = pushUser;
            mode = "0755";
          };
          "${dataDir}/incoming".d = {
            user = pushUser;
            group = pushUser;
            mode = "0755";
          };
        };
      };
  };

  testScript = ''
    import re

    SERVER = "${topo.ip.server.lan}"
    UNPAIRED = "${topo.ip.unpaired.lan}"
    DATA = "${dataDir}"
    USER = "${pushUser}"

    # IdentitiesOnly is load-bearing: without it ssh silently falls back to the
    # default identity, and the "this key must NOT authenticate" subtests would
    # be answered by the legitimate push key instead.
    OPTS = (
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR "
        "-o IdentitiesOnly=yes -o IdentityAgent=none"
    )


    def ssh(key, host, cmd=""):
        return f"ssh {OPTS} -i /root/.ssh/{key} {USER}@{host} {cmd}"


    def rsh(key):
        return f"ssh {OPTS} -i /root/.ssh/{key}"


    start_all()

    for m in (client, server, unpaired):
        m.wait_for_unit("multi-user.target")
    for m in (server, unpaired):
        m.wait_for_unit("sshd.service")
        m.wait_for_open_port(22)

    # ---------------------------------------------------------------- 1 ----
    # Topology sanity. mkTopology sets assignIP = false, so a 192.168.* address
    # anywhere means the framework's rank-based assignment leaked back in and
    # two nodes may be answering for one address.
    with subtest("topology: exactly the declared addresses"):
        for m in (client, server, unpaired):
            m.fail("ip -4 -o addr show | grep -q ' 192\\.168\\.'")
            m.succeed("test $(ip -4 -o addr show dev eth1 | wc -l) -eq 1")
        client.succeed(
            "ip -4 -o addr show dev eth1 | grep -q '${
              builtins.replaceStrings [ "." ] [ "\\\\." ] topo.ip.client.lan
            }/24'"
        )
        client.succeed(f"ping -c1 -W5 {SERVER}")
        client.succeed(f"ping -c1 -W5 {UNPAIRED}")

    client.succeed("install -d -m 700 /root/.ssh")
    for name in ("push", "attacker", "planted"):
        client.succeed(f"install -m 600 /etc/drop-box-test/{name} /root/.ssh/{name}")
    # The push client uses the default identity and its own known_hosts policy.
    client.succeed("install -m 600 /root/.ssh/push /root/.ssh/id_ed25519")

    client.succeed(
        "mkdir -p /tmp/payload/sub",
        "echo ORIGINAL > /tmp/payload/artifact.txt",
        "echo nested > /tmp/payload/sub/nested.txt",
    )

    # ---------------------------------------------------------------- 2 ----
    with subtest("a push key can rsync a directory in, and it is promoted"):
        client.succeed(
            f"DROPBOX_TARGET={USER}@{SERVER} drop-box-push --id good-drop /tmp/payload"
        )
        server.wait_until_succeeds(f"test -d {DATA}/published/good-drop", timeout=120)
        server.succeed(f"grep -qx ORIGINAL {DATA}/published/good-drop/artifact.txt")
        server.succeed(f"grep -qx nested {DATA}/published/good-drop/sub/nested.txt")
        server.succeed(f"test ! -e {DATA}/incoming/good-drop")
        server.succeed(f"test ! -e {DATA}/quarantine/good-drop")

    # ---------------------------------------------------------------- 3 ----
    with subtest("the same key cannot LIST the drop-box"):
        out = client.fail(f"rsync -e '{rsh('push')}' --list-only {USER}@{SERVER}: 2>&1")
        assert "write-only" in out, f"unexpected listing refusal: {out!r}"
        assert "good-drop" not in out, f"listing leaked names: {out!r}"
        out = client.fail(
            f"rsync -e '{rsh('push')}' --list-only {USER}@{SERVER}:good-drop/ 2>&1"
        )
        assert "artifact.txt" not in out, f"listing leaked names: {out!r}"

    # ---------------------------------------------------------------- 4 ----
    with subtest("the same key cannot READ anything back"):
        client.succeed("rm -rf /tmp/stolen && mkdir -p /tmp/stolen")
        out = client.fail(
            f"rsync -a -e '{rsh('push')}' {USER}@{SERVER}:good-drop/ /tmp/stolen/ 2>&1"
        )
        assert "write-only" in out, f"unexpected read refusal: {out!r}"
        client.succeed("test -z \"$(ls -A /tmp/stolen)\"")
        # scp asks for an arbitrary absolute path; ForceCommand replaces the
        # scp server with rrsync, so there is nothing to talk to.
        client.fail(
            f"scp {OPTS} -i /root/.ssh/push {USER}@{SERVER}:/etc/shadow /tmp/stolen/shadow"
        )
        client.succeed("test ! -e /tmp/stolen/shadow")

    # ---------------------------------------------------------------- 5 ----
    # allowOverwrite = false forces --ignore-existing server-side. The push
    # therefore SUCCEEDS and changes nothing, which is the documented and
    # deliberately surprising behaviour — assert the content, not the status.
    # This upload never gets a sentinel; subtest 11 collects it.
    with subtest("the same key cannot OVERWRITE what it already wrote"):
        client.succeed(
            f"rsync -a -e '{rsh('push')}' /tmp/payload/ {USER}@{SERVER}:stale-drop/"
        )
        server.succeed(f"grep -qx ORIGINAL {DATA}/incoming/stale-drop/artifact.txt")
        client.succeed("echo TAMPERED > /tmp/payload/artifact.txt")
        client.succeed(
            f"rsync -a -e '{rsh('push')}' /tmp/payload/ {USER}@{SERVER}:stale-drop/"
        )
        server.succeed(f"grep -qx ORIGINAL {DATA}/incoming/stale-drop/artifact.txt")
        server.fail(f"grep -q TAMPERED {DATA}/incoming/stale-drop/artifact.txt")
        client.succeed("echo ORIGINAL > /tmp/payload/artifact.txt")
        # …and it was not promoted, because no sentinel has been written.
        server.fail(f"test -e {DATA}/published/stale-drop")

    # ---------------------------------------------------------------- 6 ----
    with subtest("the same key cannot DELETE"):
        client.succeed("rm -rf /tmp/empty && mkdir -p /tmp/empty")
        out = client.fail(
            f"rsync -a --delete -e '{rsh('push')}' /tmp/empty/ {USER}@{SERVER}:stale-drop/ 2>&1"
        )
        assert "disabled on this server" in out, f"unexpected delete refusal: {out!r}"
        server.succeed(f"test -e {DATA}/incoming/stale-drop/artifact.txt")

    # ---------------------------------------------------------------- 7 ----
    with subtest("the same key cannot run an arbitrary command"):
        out = client.fail(f"{ssh('push', SERVER, 'id')} 2>&1")
        assert "uid=" not in out, f"forced command escaped: {out!r}"
        out = client.fail(f"{ssh('push', SERVER, 'cat /etc/shadow')} 2>&1")
        assert "root:" not in out, f"forced command escaped: {out!r}"
        # No command at all is an interactive shell request.
        client.fail(f"{ssh('push', SERVER)} </dev/null 2>&1")

    # ---------------------------------------------------------------- 8 ----
    # THE PAIRING. `attacker` is in the managed authorized_keys file with no
    # `command=` and no `restrict`. Only ForceCommand / DisableForwarding stand
    # between it and a shell — and the control node proves that is what is
    # standing there.
    with subtest("pairing: ForceCommand beats a key with no command= …"):
        out = server.succeed(f"cat /etc/ssh/authorized_keys.d/{USER}")
        assert "drop-box-test-attacker" in out, "control key never reached the managed file"
        assert re.search(r'^ssh-ed25519 \S+ drop-box-test-attacker', out, re.M), (
            "the control key must be UNRESTRICTED for this subtest to mean anything: "
            f"{out!r}"
        )

        out = client.fail(f"{ssh('attacker', SERVER, 'id')} 2>&1")
        assert "uid=" not in out, f"unrestricted key got a command on the paired node: {out!r}"
        client.fail(f"{ssh('attacker', SERVER)} </dev/null 2>&1")
        # DisableForwarding, not `restrict`: this key has no key options at all.
        client.fail(
            f"timeout 30 ssh {OPTS} -i /root/.ssh/attacker -o ExitOnForwardFailure=yes "
            f"-R 20022:127.0.0.1:22 {USER}@{SERVER} id"
        )

    with subtest("pairing: … and without the Match block the very same key is a shell"):
        out = client.succeed(f"{ssh('attacker', UNPAIRED, 'id')}")
        assert "uid=" in out, f"negative control did not reproduce the bypass: {out!r}"
        client.succeed(f"{ssh('attacker', UNPAIRED, 'cat /etc/hostname')}")
        client.succeed(
            f"timeout 30 ssh {OPTS} -i /root/.ssh/attacker -o ExitOnForwardFailure=yes "
            f"-R 20022:127.0.0.1:22 {USER}@{UNPAIRED} id"
        )
        # The push key is still fenced there by its own command= — which is
        # exactly why a happy-path-only test would pass against this host.
        out = client.fail(f"{ssh('push', UNPAIRED, 'id')} 2>&1")
        assert "uid=" not in out, f"the forced command in the key did not hold: {out!r}"

    # ---------------------------------------------------------------- 9 ----
    with subtest("pairing: AuthorizedKeysFile narrowing ignores ~/.ssh/authorized_keys"):
        # Premise: globally, sshd WOULD read the push user's home. Without this
        # the rest of the subtest proves nothing.
        server.succeed(
            "grep -q '^AuthorizedKeysFile .*%h/\\.ssh/authorized_keys' /etc/ssh/sshd_config"
        )
        for m in (server, unpaired):
            m.succeed(
                f"install -d -m 700 -o {USER} -g {USER} {DATA}/.ssh",
                f"install -m 600 -o {USER} -g {USER} /dev/null {DATA}/.ssh/authorized_keys",
                f"echo '${keys.planted.public}' > {DATA}/.ssh/authorized_keys",
            )
        out = client.fail(f"{ssh('planted', SERVER, 'id')} 2>&1")
        assert "Permission denied" in out, f"planted key was not rejected outright: {out!r}"
        assert "uid=" not in out, f"planted key got a command: {out!r}"
        # Same file, same key, no Match block: honoured.
        out = client.succeed(f"{ssh('planted', UNPAIRED, 'id')}")
        assert "uid=" in out, f"negative control did not reproduce the bypass: {out!r}"

    # --------------------------------------------------------------- 10 ----
    with subtest("pairing: the Match block is emitted last in sshd_config"):
        server.succeed(f"grep -q '^Match User {USER}$' /etc/ssh/sshd_config")
        for directive in ("ForceCommand", "AuthorizedKeysFile", "PermitTTY no", "DisableForwarding yes"):
            server.succeed(
                f"awk '/^Match User {USER}$/{{f=1;next}} f' /etc/ssh/sshd_config "
                f"| grep -q '{directive}'"
            )
        # Nothing unindented may follow it, or that global directive would be
        # swallowed into the Match and silently apply to this user only.
        trailing = server.succeed(
            f"awk '/^Match User {USER}$/{{f=1;next}} f && /^[^[:space:]]/' /etc/ssh/sshd_config; true"
        ).strip()
        assert trailing == "", f"directives follow the Match block: {trailing!r}"

    # --------------------------------------------------------------- 11 ----
    # The rsync "no atomic done signal" trap. stale-drop from subtest 5 has a
    # complete payload and no sentinel; it must never be promoted, and once the
    # deadline passes it must be quarantined with a reason.
    with subtest("a drop with no sentinel is quarantined, never promoted"):
        # Wait for EITHER outcome, then assert which one. Waiting only for the
        # quarantine turns "it was promoted instead" — the exact bug this
        # subtest exists for — into an opaque 3-minute timeout.
        server.wait_until_succeeds(
            f"test -f {DATA}/quarantine/stale-drop.reason "
            f"|| test -e {DATA}/published/stale-drop",
            timeout=${toString (doneTimeout + 90)},
        )
        server.fail(f"test -e {DATA}/published/stale-drop")
        server.succeed(f"test -f {DATA}/quarantine/stale-drop.reason")
        reason = server.succeed(f"cat {DATA}/quarantine/stale-drop.reason")
        assert "incomplete upload" in reason, f"unexpected reason: {reason!r}"
        assert "${toString doneTimeout}s" in reason, f"unexpected reason: {reason!r}"
        server.succeed(f"grep -qx ORIGINAL {DATA}/quarantine/stale-drop/artifact.txt")
        server.fail(f"test -e {DATA}/published/stale-drop")
        server.fail(f"test -e {DATA}/incoming/stale-drop")
        # The good drop is untouched by any of the above.
        server.succeed(f"grep -qx ORIGINAL {DATA}/published/good-drop/artifact.txt")

    # --------------------------------------------------------------- 12a ---
    with subtest("a remote path containing .. is refused by the transport"):
        out = client.fail(
            f"rsync -a -e '{rsh('push')}' /tmp/payload/ {USER}@{SERVER}:../pwned/ 2>&1"
        )
        assert "do not use .." in out.lower(), f"unexpected traversal refusal: {out!r}"
        server.fail(f"test -e {DATA}/pwned")
        server.fail("test -e /srv/pwned")

    # --------------------------------------------------------------- 12b ---
    # An absolute remote path is not honoured as an absolute path — rrsync
    # re-anchors it at the root of the chroot. Assert BOTH halves: nothing
    # appeared at the absolute path, and the payload did land inside the
    # chroot. Asserting only the first would also be satisfied by the transfer
    # simply erroring out.
    with subtest("an absolute remote path is confined to the chroot"):
        client.succeed(
            f"rsync -a -e '{rsh('push')}' /tmp/payload/ {USER}@{SERVER}:/pwned/"
        )
        server.fail("test -e /pwned")
        server.succeed(f"grep -qx ORIGINAL {DATA}/incoming/pwned/artifact.txt")

    # --------------------------------------------------------------- 12c ---
    with subtest("a leading-dot id is quarantined under a digest, not used as a path"):
        client.succeed(
            f"rsync -a -e '{rsh('push')}' /tmp/payload/ {USER}@{SERVER}:.evil/"
        )
        server.wait_until_succeeds(
            f"ls {DATA}/quarantine | grep -q '^rejected-'", timeout=120
        )
        rejected = server.succeed(
            f"ls {DATA}/quarantine | grep '^rejected-' | grep -v '\\.reason$'"
        ).split()
        assert len(rejected) == 1, f"expected one rejected drop, got {rejected!r}"
        name = rejected[0]
        assert re.fullmatch(r"rejected-[0-9a-f]{16}", name), f"bad quarantine name: {name!r}"
        reason = server.succeed(f"cat {DATA}/quarantine/{name}.reason")
        assert "rejected drop name" in reason, f"unexpected reason: {reason!r}"
        server.succeed(f"grep -qx ORIGINAL {DATA}/quarantine/{name}/artifact.txt")
        server.fail(f"test -e {DATA}/incoming/.evil")
        server.fail(f"test -e {DATA}/published/.evil")

    # --------------------------------------------------------------- 12d ---
    # The worker is a template unit, so anything that can talk to PID 1 can
    # hand it an arbitrary instance name. `../published` would turn the
    # quarantine path into the published root and rm -rf it.
    with subtest("a hand-started worker with a malicious id touches nothing"):
        before = server.succeed(f"ls -A {DATA}/published | sort")
        for bad in ("../published", "a/b", ".hidden", "/etc"):
            esc = server.succeed(f"systemd-escape -- '{bad}'").strip()
            server.succeed(f"systemctl start 'drop-box@{esc}.service'")
            journal = server.succeed(
                f"journalctl -u 'drop-box@{esc}.service' --no-pager | cat"
            )
            assert "refusing to act" in journal, f"worker acted on id {bad!r}: {journal!r}"
        after = server.succeed(f"ls -A {DATA}/published | sort")
        assert before == after, f"published/ changed: {before!r} -> {after!r}"
        server.succeed(f"grep -qx ORIGINAL {DATA}/published/good-drop/artifact.txt")
        server.fail(f"test -e {DATA}/quarantine/.hidden")
        server.fail(f"test -e {DATA}/published/b")
  '';
}
