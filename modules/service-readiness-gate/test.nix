{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "service-readiness-gate";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ./default.nix ];

      systemd.services.slow-dependency = {
        description = "Dependency that only listens after a delay";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${lib.getExe pkgs.bash} -c 'sleep 5; exec ${lib.getExe pkgs.python3} -m http.server 8099 --bind 127.0.0.1'";
      };

      systemd.services.consumer = {
        description = "Only valid once the dependency answers";
        wantedBy = [ "multi-user.target" ];
        after = [ "slow-dependency.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe pkgs.bash} -c '${lib.getExe pkgs.curl} -sf -o /dev/null --max-time 2 http://127.0.0.1:8099/ && touch /tmp/consumer-ok'";
        };
      };

      systemd.services.blocked-consumer = {
        description = "Must never run";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.bash} -c 'touch /tmp/blocked-ran'";
        };
      };

      modules.services.readiness-gates = {
        slow-dependency = {
          http = "http://127.0.0.1:8099/";
          after = [ "slow-dependency.service" ];
          timeoutSeconds = 60;
          requiredBy = [ "consumer.service" ];
        };

        never = {
          tcp = {
            host = "127.0.0.1";
            port = 9;
          };
          timeoutSeconds = 3;
          requiredBy = [ "blocked-consumer.service" ];
        };
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # The gate must not report success before the dependency answers.
    machine.wait_for_unit("slow-dependency-ready.service")
    machine.wait_for_unit("consumer.service")
    machine.succeed("test -e /tmp/consumer-ok")

    # Without the gate the consumer would have raced the 5s startup delay and
    # failed; reaching here means it was actually held back.
    machine.succeed("systemctl show consumer.service -p Requires --value | grep -q slow-dependency-ready")

    # A gate that cannot pass must fail, and must stop its consumer running.
    machine.wait_until_fails("systemctl is-active never-ready.service")
    machine.fail("test -e /tmp/blocked-ran")
    machine.fail("systemctl is-active blocked-consumer.service")
  '';
}
