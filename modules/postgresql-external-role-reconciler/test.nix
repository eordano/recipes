# NixOS VM test for the postgresql-external-role-reconciler module.
#
# Run it standalone (no flake needed):
#
#   nix-build test.nix --arg pkgs 'import <nixpkgs> { system = "x86_64-linux"; }'
#
# or from a flake:
#
#   pkgs.callPackage ./modules/postgresql-external-role-reconciler/test.nix { }
#
# Two nodes, wired with lib/nixos-test-topology so neither of them carries a
# framework-assigned phantom address:
#
#   db      runs PostgreSQL. Knows nothing about the reconciler.
#   runner  runs the module. Runs NO PostgreSQL at all -- asserted, because
#           "reconcile a server this host does not run" is the entire premise.
#
# One subnet is enough here: unlike a filtering test (README trap 4) there is no
# forward hook to transit, and `db` being a different machine is exactly what
# makes it external. The test asserts `inet_server_addr()` comes back as db's
# topology address, so a psql that had silently fallen back to a local socket
# would fail rather than pass.
#
# What it proves, and for each one what breaking the module would look like:
#
#   0. (eval-time) the identifier assertion rejects a role name that is not a
#      bare SQL identifier, and accepts the config this test actually deploys.
#   1. The role is created and AUTHENTICATES from the runner with the password
#      that only ever existed in a 0400 root:root file -- a file the reconciler
#      unit could not have read directly, since it runs as a DynamicUser and
#      gets the bytes through LoadCredential. `nobody` is shown to be unable to
#      read it.
#   2. `clauses` landed: the role is NOSUPERUSER/NOCREATEDB/NOCREATEROLE/
#      NOREPLICATION/LOGIN.
#   3. `revokePublicConnect` landed: PUBLIC has no CONNECT on the database.
#   4. The read-only grant is read-only in BOTH directions -- SELECT succeeds,
#      and INSERT/UPDATE/DELETE/CREATE TABLE each fail with a permission error
#      (asserted on the server's message, not merely on a non-zero exit).
#      Sequences: SELECT works, nextval() does not.
#   5. `defaultPrivilegesFrom` works: a table created by the owner role AFTER
#      the reconcile is readable without re-running anything. Drop that option
#      and this is the assertion that goes red -- `GRANT SELECT ON ALL TABLES`
#      alone is a point-in-time snapshot.
#   6. ROTATION: rewriting the key file alone changes nothing (control), and
#      after a restart the OLD password is rejected with "password
#      authentication failed" while the NEW one works and keeps every grant.
#   7. ORDERING, causally: with both units stopped and the role's password
#      drifted out-of-band on the server, the consumer's own probe command is
#      shown to FAIL (control), and then `systemctl start` of the consumer
#      alone succeeds -- because `Requires=`/`After=` pulled the reconciler in
#      first and it repaired the credential before the consumer ran.
{ pkgs, ... }:
let
  topoLib = import ../../lib/nixos-test-topology;

  topo = topoLib.mkTopology {
    subnets.lan.vlan = 1;
    hosts = {
      db.addresses.lan = 10;
      runner.addresses.lan = 20;
    };
  };

  dbIp = topo.ip.db.lan;

  superPw = "sup3r-pw-not-a-real-secret";
  ownerPw = "own3r-pw-not-a-real-secret";
  readerV1 = "reader-pw-generation-one";
  readerV2 = "reader-pw-generation-two";

  pgPkg = pkgs.postgresql;

  # Server-side bootstrap. This is the "someone else's database" half: it is
  # deliberately NOT expressed with the module under test.
  initialScript = pkgs.writeText "external-db-initial.sql" ''
    ALTER ROLE postgres WITH PASSWORD '${superPw}';
  '';

  fixtureSql = pkgs.writeText "external-db-fixture.sql" ''
    \connect appdb
    CREATE TABLE IF NOT EXISTS pre_existing (id integer PRIMARY KEY, note text);
    INSERT INTO pre_existing VALUES (1, 'seeded-before-reconcile') ON CONFLICT (id) DO NOTHING;
    CREATE SEQUENCE IF NOT EXISTS pre_seq;
  '';

  # --- 0. eval-time checks ---------------------------------------------------
  evalWith =
    roles:
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
          services.postgresql-external-roles = {
            enable = true;
            host = "10.9.9.9";
            inherit roles;
          };
        }
      ];
    }).config;

  goodEval = evalWith {
    reader.readOnly = [ { database = "appdb"; } ];
  };
  evilEval = evalWith {
    "evil\"; DROP DATABASE appdb; --" = { };
  };

  failing = cfg: builtins.filter (a: !a.assertion) cfg.assertions;

  # The config this test deploys must be assertion-clean, ...
  goodOk = failing goodEval == [ ];
  # ... and a role name that is not a bare identifier must be REJECTED, not
  # quietly interpolated into the DDL.
  evilOk = builtins.any (
    a: pkgs.lib.hasInfix "SQL identifiers" a.message && pkgs.lib.hasInfix "DROP DATABASE" a.message
  ) (failing evilEval);
  # The generated unit must take the secret through LoadCredential, never as a
  # readable path baked into the script.
  wiredOk =
    let
      unit =
        (evalWith {
          reader.passwordFile = "/run/agenix/pg-password-reader";
        }).systemd.services."pg-role-reader";
    in
    unit.serviceConfig.LoadCredential == [ "password:/run/agenix/pg-password-reader" ]
    && unit.serviceConfig.DynamicUser
    && !(pkgs.lib.hasInfix "/run/agenix/pg-password-reader" unit.script);
in
assert goodOk;
assert evilOk;
assert wiredOk;
pkgs.testers.runNixOSTest {
  name = "postgresql-external-role-reconciler";

  nodes = {
    db =
      { config, ... }:
      {
        imports = [ topo.nodes.db ];

        environment.systemPackages = [ pgPkg ];
        networking.firewall.allowedTCPPorts = [ 5432 ];

        services.postgresql = {
          enable = true;
          package = pgPkg;
          enableTCPIP = true;
          ensureDatabases = [ "appdb" ];
          inherit initialScript;
          # Plain definition: sorts before the module's own mkAfter defaults, so
          # this rule wins for the test subnet. Password auth, not trust --
          # otherwise "the role can authenticate" would prove nothing.
          authentication = "host all all ${topo.cidr.lan} scram-sha-256";
        };

        systemd.services.pg-fixture = {
          description = "Seed objects that exist before any reconcile";
          wantedBy = [ "multi-user.target" ];
          after = [ "postgresql-setup.service" ];
          requires = [ "postgresql-setup.service" ];
          path = [ config.services.postgresql.package ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "postgres";
          };
          script = "psql -X -q -v ON_ERROR_STOP=1 -d postgres -f ${fixtureSql}";
        };
      };

    runner =
      { config, ... }:
      {
        imports = [
          topo.nodes.runner
          ./default.nix
          (topoLib.fixtures.secretsStub {
            contents = {
              pg-superuser = superPw;
              pg-password-appowner = ownerPw;
              pg-password-reader = readerV1;
            };
            consumers = [
              "pg-role-appowner.service"
              "pg-role-reader.service"
              "appconsumer.service"
            ];
          })
        ];

        age.secrets = {
          pg-superuser = { };
          pg-password-appowner = { };
          pg-password-reader = { };
        };

        environment.systemPackages = [ pgPkg ];

        services.postgresql-external-roles = {
          enable = true;
          package = pgPkg;
          host = dbIp;
          sslMode = "disable";
          superuserPasswordFile = config.age.secrets.pg-superuser.path;
          readyTimeoutSec = 90;

          roles = {
            appowner = {
              passwordFile = config.age.secrets.pg-password-appowner.path;
              ownsDatabases = [ "appdb" ];
              revokePublicConnect = [ "appdb" ];
            };

            reader = {
              passwordFile = config.age.secrets.pg-password-reader.path;
              afterRoles = [ "appowner" ];
              consumers = [ "appconsumer.service" ];
              readOnly = [
                {
                  database = "appdb";
                  schemas = [ "public" ];
                  sequences = true;
                  defaultPrivilegesFrom = "appowner";
                }
              ];
            };
          };
        };

        # Stands in for the real workload. It authenticates as the reader with
        # the same key file the reconciler drives, so "the consumer started"
        # and "the credential was usable when it started" are the same event.
        systemd.services.appconsumer = {
          description = "Workload that must never run against a stale credential";
          wantedBy = [ "multi-user.target" ];
          path = [ pgPkg ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            DynamicUser = true;
            LoadCredential = "password:${config.age.secrets.pg-password-reader.path}";
            StateDirectory = "appconsumer";
          };
          script = ''
            set -euo pipefail
            PGPASSWORD=$(cat "$CREDENTIALS_DIRECTORY/password")
            export PGPASSWORD
            psql -X -q -v ON_ERROR_STOP=1 -h ${dbIp} -p 5432 -U reader -d appdb \
              -tAc "select current_user" > /var/lib/appconsumer/probe
          '';
        };
      };
  };

  testScript = ''
    DBHOST = "${dbIp}"
    RUNNERIP = "${topo.ip.runner.lan}"
    SUPER = "${superPw}"
    OWNER = "${ownerPw}"
    V1 = "${readerV1}"
    V2 = "${readerV2}"
    SECRET = "/run/agenix/pg-password-reader"

    def psql(user, pw, db, sql):
        return (
            f"PGPASSWORD='{pw}' psql -X -q -v ON_ERROR_STOP=1 "
            f"-h {DBHOST} -p 5432 -U {user} -d {db} -tAc \"{sql}\" 2>&1"
        )

    def reader(pw, sql, db="appdb"):
        return psql("reader", pw, db, sql)

    def owner(sql, db="appdb"):
        return psql("appowner", OWNER, db, sql)

    def superq(sql, db="postgres"):
        return psql("postgres", SUPER, db, sql)

    start_all()

    db.wait_for_unit("postgresql.service")
    db.wait_for_unit("pg-fixture.service")
    db.wait_for_open_port(5432)
    runner.wait_for_unit("multi-user.target")
    runner.wait_for_unit("test-secrets-seed.service")

    with subtest("topology: no framework phantom addresses"):
        for m in (db, runner):
            m.fail("ip -4 -o addr show | grep -q 192.168.")
        assert runner.succeed("ip -4 -o addr show eth1").count("inet ") == 1
        assert db.succeed("ip -4 -o addr show eth1").count("inet ") == 1
        db.succeed(f"ip -4 -o addr show eth1 | grep -q 'inet {DBHOST}/'")
        runner.succeed(f"ip -4 -o addr show eth1 | grep -q 'inet {RUNNERIP}/'")

    with subtest("the reconciler host runs no PostgreSQL of its own"):
        runner.fail("systemctl is-active postgresql.service")
        runner.fail("test -e /run/postgresql/.s.PGSQL.5432")

    # The fixture objects and the superuser password are seeded by the server at
    # its own pace, so pin the reference reconcile here instead of racing boot.
    # Re-running is also the module's normal mode: it is a reconciler.
    runner.succeed("systemctl restart pg-role-appowner.service")
    runner.succeed("systemctl restart pg-role-reader.service")
    runner.succeed("systemctl is-active pg-role-appowner.service")
    runner.succeed("systemctl is-active pg-role-reader.service")

    with subtest("secret stayed unreadable; the unit got it via LoadCredential"):
        runner.succeed(f"stat -c %a:%U:%G {SECRET} | grep -qx 400:root:root")
        runner.fail(f"runuser -u nobody -- cat {SECRET}")
        runner.succeed(
            "systemctl show -p DynamicUser --value pg-role-reader.service | grep -qx yes"
        )
        # `systemctl show -p LoadCredential` renders "[unprintable]", so read the
        # unit file. (The exact list is also asserted at eval time, above.)
        runner.succeed(
            "systemctl cat pg-role-reader.service"
            f" | grep -q '^LoadCredential=.*password:{SECRET}'"
        )

    with subtest("1. the role authenticates with the password from the key file"):
        who = runner.succeed(reader(V1, "select current_user")).strip()
        assert who == "reader", who
        # ... and it is genuinely the remote server answering, not a local socket.
        srv = runner.succeed(reader(V1, "select inet_server_addr()")).strip()
        assert srv == DBHOST, srv
        # A wrong password must be rejected, or "it authenticated" means nothing.
        out = runner.fail(reader("definitely-not-the-password", "select 1"))
        assert "password authentication failed" in out, out

    with subtest("2. clauses were applied"):
        attrs = runner.succeed(
            superq(
                "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolcanlogin"
                " from pg_roles where rolname = 'reader'"
            )
        ).strip()
        assert attrs == "f|f|f|f|t", attrs

    with subtest("3. revokePublicConnect took CONNECT away from PUBLIC"):
        pub = runner.succeed(
            superq("select has_database_privilege('public', 'appdb', 'CONNECT')")
        ).strip()
        assert pub == "f", pub
        owns = runner.succeed(
            superq("select pg_get_userbyid(datdba) from pg_database where datname = 'appdb'")
        ).strip()
        assert owns == "appowner", owns

    with subtest("4. the read-only grant is read-only in both directions"):
        got = runner.succeed(reader(V1, "select note from pre_existing where id = 1")).strip()
        assert got == "seeded-before-reconcile", got

        for stmt in (
            "insert into pre_existing values (99, 'nope')",
            "update pre_existing set note = 'nope' where id = 1",
            "delete from pre_existing where id = 1",
        ):
            out = runner.fail(reader(V1, stmt))
            assert "permission denied for table pre_existing" in out, (stmt, out)

        out = runner.fail(reader(V1, "create table reader_should_not (id int)"))
        assert "permission denied for schema public" in out, out

        # The write attempts really were rejected, not silently swallowed.
        rows = runner.succeed(superq("select count(*) from pre_existing", "appdb")).strip()
        assert rows == "1", rows
        note = runner.succeed(
            superq("select note from pre_existing where id = 1", "appdb")
        ).strip()
        assert note == "seeded-before-reconcile", note

        # sequences = true grants SELECT, and only SELECT.
        runner.succeed(reader(V1, "select last_value from pre_seq"))
        out = runner.fail(reader(V1, "select nextval('pre_seq')"))
        assert "permission denied for sequence pre_seq" in out, out

    with subtest("5. defaultPrivilegesFrom covers objects created after the reconcile"):
        # Created by the owner role, from this host, with the password the
        # reconciler drove -- so this doubles as proof that role authenticates.
        runner.succeed(owner("create table created_later (id int)"))
        runner.succeed(owner("insert into created_later values (7)"))
        runner.succeed(owner("create sequence later_seq"))

        # No reconcile in between. If defaultPrivilegesFrom were dropped, the
        # GRANT ON ALL TABLES snapshot would not cover this and the next line
        # would fail with "permission denied for table created_later".
        val = runner.succeed(reader(V1, "select id from created_later")).strip()
        assert val == "7", val
        runner.succeed(reader(V1, "select last_value from later_seq"))

        out = runner.fail(reader(V1, "insert into created_later values (8)"))
        assert "permission denied for table created_later" in out, out
        out = runner.fail(reader(V1, "select nextval('later_seq')"))
        assert "permission denied for sequence later_seq" in out, out

    with subtest("6. rotation: old password dies, new password lives"):
        runner.succeed(reader(V1, "select 1"))

        runner.succeed(f"install -m 0400 -o root -g root /dev/null {SECRET}.new")
        runner.succeed(f"printf %s '{V2}' > {SECRET}.new")
        runner.succeed(f"mv {SECRET}.new {SECRET}")

        # Control: rewriting the file alone must change nothing. If this line
        # ever fails, the rotation assertions below would be measuring some
        # other effect.
        runner.succeed(reader(V1, "select 1"))
        out = runner.fail(reader(V2, "select 1"))
        assert "password authentication failed" in out, out

        runner.succeed("systemctl restart pg-role-reader.service")

        out = runner.fail(reader(V1, "select 1"))
        assert "password authentication failed" in out, out
        runner.succeed(reader(V2, "select 1"))

        # Rotation must not cost the role its grants.
        got = runner.succeed(reader(V2, "select note from pre_existing where id = 1")).strip()
        assert got == "seeded-before-reconcile", got
        out = runner.fail(reader(V2, "insert into pre_existing values (98, 'nope')"))
        assert "permission denied for table pre_existing" in out, out

    with subtest("7. a consumer cannot start before the credential is usable"):
        # The causal experiment comes FIRST, deliberately: a `systemctl show`
        # check alone would still pass if the edges existed but did nothing.
        runner.succeed("systemctl stop appconsumer.service pg-role-reader.service")
        runner.succeed("rm -f /var/lib/appconsumer/probe")

        # Drift the password out-of-band, the way a restore or a manual ALTER
        # would. Now the key file on this host is right and the server is wrong.
        runner.succeed(
            superq("alter role reader with password 'drifted-out-of-band'")
        )

        # Control: the consumer's own probe command fails right now. Without
        # this line, "the consumer started fine" would be satisfied by a
        # credential that never needed repairing.
        out = runner.fail(reader(V2, "select current_user"))
        assert "password authentication failed" in out, out

        # Start ONLY the consumer. Requires= must pull the reconciler in and
        # After= must run it first, or the probe inside the unit fails.
        runner.succeed("systemctl start appconsumer.service")
        runner.succeed("systemctl is-active pg-role-reader.service")
        runner.succeed("systemctl is-active appconsumer.service")
        probe = runner.succeed("cat /var/lib/appconsumer/probe").strip()
        assert probe == "reader", probe

        # ... and the reconciler really did finish before the consumer began.
        started = int(
            runner.succeed(
                "systemctl show -p ActiveEnterTimestampMonotonic --value pg-role-reader.service"
            ).strip()
        )
        consumed = int(
            runner.succeed(
                "systemctl show -p ExecMainStartTimestampMonotonic --value appconsumer.service"
            ).strip()
        )
        assert 0 < started <= consumed, (started, consumed)

        # Only now the declarative edges, as a readable diagnosis of the above.
        runner.succeed(
            "systemctl show -p After appconsumer.service | grep -q pg-role-reader.service"
        )
        runner.succeed(
            "systemctl show -p Requires appconsumer.service | grep -q pg-role-reader.service"
        )

    print("=== postgresql-external-role-reconciler test passed ===")
  '';
}
