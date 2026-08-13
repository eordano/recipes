{ pkgs, ... }:
let
  sshHostPub = builtins.readFile ./test-keys/test-host-key.pub;
  sshAccessPub = builtins.readFile ./test-keys/test-ssh-key.pub;

  sshHost = pkgs.runCommand "ssh-host-key" { } ''
    mkdir -p $out
    cp ${./test-keys/test-host-key} $out/ssh_host_ed25519_key
    cp ${./test-keys/test-host-key.pub} $out/ssh_host_ed25519_key.pub
    chmod 600 $out/ssh_host_ed25519_key
  '';
  sshAccess = pkgs.runCommand "ssh-access-key" { } ''
    mkdir -p $out
    cp ${./test-keys/test-ssh-key} $out/id_ed25519
    cp ${./test-keys/test-ssh-key.pub} $out/id_ed25519.pub
    chmod 600 $out/id_ed25519
  '';
in
pkgs.testers.nixosTest {
  name = "remote-luks-unlock";

  nodes = {
    machine =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      {
        virtualisation = {
          emptyDiskImages = [
            512
            512
          ];
          useBootLoader = true;
          mountHostNixStore = true;
          useEFIBoot = true;
          vlans = [ 1 ];
        };
        boot.loader.systemd-boot.enable = true;
        boot.initrd.availableKernelModules = [
          "virtio_pci"
          "virtio_net"
        ];

        imports = [ ./default.nix ];

        environment.systemPackages = [
          pkgs.cryptsetup
          pkgs.jq
        ];

        modules.unlock-ssh = {
          enable = true;
          hostKeys = {
            ssh_host_ed25519_key = "${sshHost}/ssh_host_ed25519_key";
          };
          authorizedKeys = [ sshAccessPub ];
          networkInterface = "eth1";
          static = {
            enable = true;
            address = "192.168.1.${toString config.virtualisation.test.nodeNumber}/24";
            gateway = "192.168.1.1";
          };
        };

        specialisation.boot-luks.configuration = {
          boot.initrd.luks.devices = lib.mkVMOverride {
            cryptroot.device = "/dev/vdb";
            cryptroot2.device = "/dev/vdc";
          };
          virtualisation = {
            rootDevice = "/dev/mapper/cryptroot";
            fileSystems."/cryptroot2" = {
              device = "/dev/mapper/cryptroot2";
              fsType = "ext4";
            };
          };
        };
      };
    client =
      { pkgs, ... }:
      {
        virtualisation.vlans = [ 1 ];
        environment = {
          systemPackages = with pkgs; [ netcat ];

          etc = {
            knownHosts = {
              text = "machine ${sshHostPub}";
            };
            sshKey = {
              source = "${sshAccess}/id_ed25519";
              mode = "0600";
            };
          };
        };
      };
  };

  testScript = ''
    start_all()

    # First boot is the unencrypted base generation. Format both LUKS
    # volumes with the same passphrase, then switch the default boot entry
    # to the encrypted specialisation.
    machine.wait_for_unit("multi-user.target")
    machine.succeed("echo -n supersecret | cryptsetup luksFormat -q --iter-time=1 /dev/vdb -")
    machine.succeed("echo -n supersecret | cryptsetup luksOpen   -q               /dev/vdb cryptroot")
    machine.succeed("mkfs.ext4 /dev/mapper/cryptroot")
    machine.succeed("echo -n supersecret | cryptsetup luksFormat -q --iter-time=1 /dev/vdc -")
    machine.succeed("echo -n supersecret | cryptsetup luksOpen   -q               /dev/vdc cryptroot2")
    machine.succeed("mkfs.ext4 /dev/mapper/cryptroot2")

    # systemd-boot entry files are named after a hash of their contents, so the
    # specialisation's entry id has to be looked up by title rather than guessed.
    entry_id = machine.succeed(
        "bootctl list --json=short | jq -r '.[] | select(.title | test(\"boot-luks\")) | .id'"
    ).strip()
    assert entry_id, "no systemd-boot entry found for the boot-luks specialisation"

    machine.succeed(f"bootctl set-default {entry_id}")
    assert entry_id in machine.succeed("bootctl list --json=short | jq -r '.[] | select(.isDefault) | .id'"), \
        "bootctl set-default did not select the boot-luks specialisation"
    machine.succeed("sync")
    machine.crash()

    # Encrypted boot: the machine stops in the initrd waiting for the LUKS
    # passphrase. The console prompt confirms the request is pending (so the
    # password agent will have something to answer).
    machine.start()
    machine.wait_for_console_text("Please enter passphrase for disk cryptroot")

    # The operator reaches the initrd over SSH. With promptOnLogin the login
    # shell runs `systemd-tty-ask-password-agent --query`, so simply piping
    # the passphrase into the SSH session answers the prompt and resumes
    # boot -- no manual command needed.
    def ssh_is_up(_) -> bool:
        status, _ = client.execute("nc -z machine 22")
        return status == 0

    def still_in_initrd() -> bool:
        # While the disk is locked the initrd SSH server is reachable. Once
        # the passphrase is accepted the initrd tears down and :22 stops
        # answering, so a closed port means we left the initrd (booting).
        status, _ = client.execute("nc -z machine 22")
        return status == 0

    def send_passphrase(passphrase: str) -> None:
        # promptOnLogin makes the login shell the askpass agent, so whatever
        # we pipe in is taken as the answer to the pending LUKS prompt. -tt
        # forces a PTY (the agent needs a tty to read from) -- without it the
        # session closes immediately with no prompt.
        client.execute(
            f"echo {passphrase} | ssh -tt -i /etc/sshKey"
            " -o UserKnownHostsFile=/etc/knownHosts -o StrictHostKeyChecking=no"
            " -o ConnectTimeout=10 machine"
        )

    client.wait_for_unit("network.target")
    with client.nested("waiting for initrd SSH server to come up"):
        retry(ssh_is_up)

    # --- Wrong passphrase: the operator fat-fingers it ---
    with client.nested("submitting a WRONG passphrase"):
        send_passphrase("totally-wrong-passphrase")

    # The wrong answer must NOT unlock the disk. systemd-cryptsetup rejects
    # it and re-posts the password request, so the machine is still sitting in
    # the initrd with the SSH server reachable.
    machine.wait_for_console_text("Please enter passphrase for disk cryptroot")
    assert still_in_initrd(), "machine left the initrd after a WRONG passphrase -- should still be locked"

    # --- Recovery: re-connect and submit the CORRECT passphrase ---
    # Because --query answers the *currently pending* request and then exits,
    # recovery means simply SSHing in again. Retry to ride over the brief
    # window between cryptsetup rejecting the bad answer and re-posting a new
    # request (during which a fresh --query would find nothing to answer).
    def recover(_) -> bool:
        send_passphrase("supersecret")
        return not still_in_initrd()

    with client.nested("recovering with the CORRECT passphrase"):
        retry(recover)

    # Once the passphrase is accepted, both volumes unlock (key reuse) and
    # the machine continues into stage 2.
    machine.wait_for_unit("multi-user.target")

    assert "/dev/mapper/cryptroot on / type ext4" in machine.succeed("mount"), "/dev/mapper/cryptroot does not appear in mountpoints list"
    assert "/dev/mapper/cryptroot2 on /cryptroot2 type ext4" in machine.succeed("mount")
  '';
}
