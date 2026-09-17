let
  hostGateway = "10.0.2.2";

  slirpHostLoopback = "slirp4netns:allow_host_loopback=true";

  mkNode =
    {
      runtime ? "runsc",
      makeDefault ? false,
      gvisorPackage ? null,
      extraPackages ? [ ],
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

      virtualisation.containers.containersConf.settings = lib.recursiveUpdate {
        engine.runtimes.${runtime} = [ "${gvisor}/bin/runsc" ];
      } (lib.optionalAttrs makeDefault { engine.runtime = runtime; });

      environment.systemPackages = [
        pkgs.slirp4netns
        gvisor
      ]
      ++ extraPackages;

      virtualisation.memorySize = lib.mkDefault memorySize;
      virtualisation.diskSize = lib.mkDefault diskSize;
    };

  examples.hostServiceFromRunsc =
    { pkgs }:
    let
      port = 8080;
      token = "hello-from-the-vm-node";

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
