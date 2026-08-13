# nixos-test-gvisor-podman
#
# A NixOS-test node configuration that runs podman with the gVisor (`runsc`)
# OCI runtime, plus the two things that are needed for a container under runsc
# to reach a service on the VM it runs in.
#
# Three separate traps sit between "add gvisor to the test" and a green test,
# and each one masks the next: registering the runtime the obvious way stops
# the test from EVALUATING, then podman exits 127 for a missing binary, then
# the fetch fails with exit 4 that looks like a network bug. README.md has the
# error strings for all three, in the order they appear.
#
#   node = (import ./lib/nixos-test-gvisor-podman).mkNode { };
#
#   nodes.machine = { ... }: { imports = [ node ]; };
#   # -> podman + /etc/containers/containers.conf registering `runsc`
#   # -> slirp4netns on PATH
#
#   podman run --rm --runtime=runsc \
#     --network=slirp4netns:allow_host_loopback=true <image> ...
#
# `examples.hostServiceFromRunsc` at the bottom is a complete runnable test
# that proves the container is really gVisor and that the loopback flag is what
# decides whether the host service is reachable.

let
  # slirp4netns puts the container on 10.0.2.0/24 with its gateway at 10.0.2.2.
  # That gateway is how the container reaches back into the network namespace
  # podman was invoked from -- i.e. the VM node itself. It is a slirp4netns
  # default, not something the node config chooses.
  hostGateway = "10.0.2.2";

  # The `--network=` value to use when the container has to reach a service on
  # the VM's LOOPBACK. Plain `slirp4netns` is NOT enough for that: without
  # allow_host_loopback the gateway address is unreachable and the failure looks
  # like a routing or firewall problem rather than a missing flag. A service on
  # an address the node holds on a real interface needs no flag.
  slirpHostLoopback = "slirp4netns:allow_host_loopback=true";

  mkNode =
    {
      # Name podman will know the runtime by, i.e. what `--runtime=` takes.
      runtime ? "runsc",
      # Make it the engine-wide default so `--runtime=` can be omitted. Off by
      # default: a test that names the runtime on every `podman run` also
      # documents which runtime each assertion is about.
      makeDefault ? false,
      # Defaults to pkgs.gvisor. Override to pin or patch it.
      gvisorPackage ? null,
      extraPackages ? [ ],
      # gVisor's sentry is a second userspace kernel inside an already-nested
      # VM; the NixOS test default (1024 MiB at the time of writing) is tight.
      # mkDefault, so a node module can still raise it.
      memorySize ? 2048,
      diskSize ? 4096,
    }:
    {
      pkgs,
      lib,
      ...
    }:
    let
      gvisor = if gvisorPackage != null then gvisorPackage else pkgs.gvisor;
    in
    {
      virtualisation.podman.enable = true;

      # THE supported way to register an extra OCI runtime. Writing
      # environment.etc."containers/containers.conf" by hand instead collides
      # with the definition the virtualisation.containers module already emits
      # (nixos/modules/virtualisation/containers.nix, the environment.etc block
      # that generates containers.conf from this very option), and the test
      # then fails to evaluate. See README trap 1.
      #
      # recursiveUpdate, not `//`: `//` is shallow and the optional
      # `engine.runtime` would replace the whole `engine` attrset, silently
      # dropping `engine.runtimes`.
      virtualisation.containers.containersConf.settings = lib.recursiveUpdate {
        engine.runtimes.${runtime} = [ "${gvisor}/bin/runsc" ];
      } (lib.optionalAttrs makeDefault { engine.runtime = runtime; });

      # slirp4netns is a separate executable that podman looks up on PATH at
      # run time. The podman module only pulls it in when the containers.conf
      # default_rootless_network_cmd is slirp4netns, which is not the case for
      # an explicit `--network=slirp4netns` on a root container. Without it
      # podman exits 127. See README trap 2.
      #
      # gvisor itself is on PATH only for convenience (`runsc --version` in a
      # testScript); podman invokes it through the absolute path above.
      environment.systemPackages = [
        pkgs.slirp4netns
        gvisor
      ]
      ++ extraPackages;

      virtualisation.memorySize = lib.mkDefault memorySize;
      virtualisation.diskSize = lib.mkDefault diskSize;
    };

  # A complete, runnable single-node test. Build it with:
  #
  #   nix build --impure --expr '
  #     let pkgs = import <nixpkgs> {}; in
  #     (import ./lib/nixos-test-gvisor-podman).examples.hostServiceFromRunsc { inherit pkgs; }'
  #
  # Needs /dev/kvm on the executing machine like any NixOS test, but NOT nested
  # KVM: runsc's default platform is systrap, and the container still runs with
  # /dev/kvm deleted inside the node. Only `--platform=kvm` would need nesting.
  examples.hostServiceFromRunsc =
    { pkgs }:
    let
      port = 8080;
      token = "hello-from-the-vm-node";

      # An empty tar imported as an image, plus bind mounts of the store and
      # the system profile. Cheaper than building an image layer, and it means
      # the container's `wget` is the same binary the node has.
      containerMounts = "-v /nix/store:/nix/store -v /run/current-system/sw/bin:/bin";
    in
    pkgs.testers.runNixOSTest {
      name = "nixos-test-gvisor-podman-example";

      nodes.machine =
        { pkgs, ... }:
        {
          imports = [ (mkNode { }) ];

          environment.systemPackages = [ pkgs.wget ];
          system.stateVersion = "25.05";

          # The service the container has to reach. Bound to 127.0.0.1 on
          # purpose: that is exactly what allow_host_loopback controls.
          systemd.services.host-http = {
            description = "HTTP server on the node's loopback";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              DynamicUser = true;
              Restart = "on-failure";
              ExecStart =
                let
                  script = pkgs.writeText "host-http.py" ''
                    from http.server import HTTPServer, BaseHTTPRequestHandler

                    class Handler(BaseHTTPRequestHandler):
                        def do_GET(self):
                            self.send_response(200)
                            self.send_header("Content-Type", "text/plain")
                            self.end_headers()
                            self.wfile.write(b"${token}")
                        def log_message(self, *args):
                            pass

                    HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
                  '';
                in
                "${pkgs.python3}/bin/python3 ${script}";
            };
          };
        };

      testScript = ''
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("host-http.service")
        machine.wait_for_open_port(${toString port}, addr = "127.0.0.1")

        url = "http://${hostGateway}:${toString port}/"

        def run(network, cmd):
            return (
                "podman run --rm --runtime=runsc "
                + "--network=" + network + " "
                + "${containerMounts} scratchimg " + cmd
            )

        with subtest("the runtime is registered in the GENERATED containers.conf"):
            conf = machine.succeed("cat /etc/containers/containers.conf")
            assert "runsc" in conf, f"runsc missing from containers.conf:\n{conf}"
            # The file is a store symlink written by the containers module, not
            # a hand-rolled environment.etc entry.
            link = machine.succeed("readlink -f /etc/containers/containers.conf").strip()
            assert link.startswith("/nix/store/"), link

        with subtest("slirp4netns is on PATH"):
            machine.succeed("command -v slirp4netns")

        with subtest("import a scratch image"):
            machine.succeed("tar cv --files-from /dev/null | podman import - scratchimg")

        with subtest("the container really runs on gVisor, not the host kernel"):
            # runsc's sentry announces itself in the container's dmesg. This is
            # the check that separates "podman accepted --runtime=runsc" from
            # "the workload is actually running on gVisor".
            # Not `log`: the test driver binds that name to its own logger and
            # the testScript type check rejects the assignment.
            kmsg = machine.succeed(run("none", "/bin/dmesg"))
            assert "gVisor" in kmsg, f"container dmesg is not gVisor's:\n{kmsg}"

        with subtest("plain slirp4netns cannot reach the node's loopback"):
            rc, out = machine.execute(run("slirp4netns", "/bin/wget -q -O - " + url))
            assert rc == 4, f"expected wget exit 4 (network failure), got {rc}:\n{out}"

        with subtest("allow_host_loopback is what makes the node reachable"):
            body = machine.succeed(run("${slirpHostLoopback}", "/bin/wget -q -O - " + url))
            assert body.strip() == "${token}", f"unexpected body: {body!r}"

        print("=== nixos-test-gvisor-podman example passed ===")
      '';
    };
in
{
  inherit
    mkNode
    hostGateway
    slirpHostLoopback
    examples
    ;
}
