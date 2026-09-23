{
  pkgs,
  inputs,
}: let
  package = import ../../systems/nix-slopfucker/hermes-package.nix {
    inherit pkgs;
    inherit (inputs) hermes-agent;
  };
  python = "${package.hermesVenv}/bin/python3";
  gatewayFixture = pkgs.writeShellScriptBin "hermes" ''
    exec ${python} ${./gateway.py} ${package}/bin/hermes "$@"
  '';
  observedPackage = pkgs.symlinkJoin {
    name = "hermes-observed-gateway";
    paths = [gatewayFixture package];
  };
  uid = 1100;
  home = "/var/lib/hermes/.hermes";
in
  pkgs.testers.runNixOSTest {
    name = "hermes-workers";
    nodes.machine = {
      virtualisation.memorySize = 3072;
      containers.hermes = {
        autoStart = true;
        ephemeral = true;
        privateNetwork = true;
        hostAddress = "10.200.0.1";
        localAddress = "10.200.0.2";
        specialArgs = {
          inherit inputs;
          terminalIdentityEnv = ["TERM"];
        };
        config = {lib, ...}: {
          imports = [
            inputs.hermes-agent.nixosModules.default
            ../../systems/nix-slopfucker/hermes-workers.nix
          ];
          users.users.hermes.uid = lib.mkForce uid;
          nix.enable = false;
          services.hermes-agent = {
            enable = true;
            package = observedPackage;
            extraPackages = [pkgs.hello];
            settings = {
              terminal.cwd = "/var/lib/hermes/workspace";
              cron.script_timeout_seconds = 420;
              logging.level = "DEBUG";
            };
          };
          environment.systemPackages = [pkgs.util-linux pkgs.python3];
          systemd.tmpfiles.rules = [
            "f /srv/worker-canary 0666 hermes hermes - canary"
          ];
          systemd.services.test-peer = {
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              User = "hermes";
              RuntimeDirectory = "hermes-test-peer";
              ExecStart = "${pkgs.python3}/bin/python3 ${./peer.py} serve /srv/worker-canary /run/hermes-test-peer/ready.json";
            };
          };
          system.stateVersion = "26.05";
        };
      };
    };
    testScript = ''
      from contextlib import contextmanager
      import errno
      import json
      import shlex

      def c(command):
          return machine.succeed(
              "systemd-run --machine=hermes --wait --pipe --collect --quiet "
              "${pkgs.bash}/bin/bash -lc " + shlex.quote(command)
          ).strip()

      def user(command):
          return c("runuser -u hermes -- env HOME=/var/lib/hermes "
                   "HERMES_HOME=${home} XDG_RUNTIME_DIR=/run/user/${toString uid} "
                   "${pkgs.bash}/bin/bash -c " + shlex.quote(command))

      def report(directory):
          return json.loads(c("cat " + directory + "/probe.json"))

      def wait_for_worker_command(command, timeout):
          try:
              machine.wait_until_succeeds(command, timeout=timeout)
          except Exception as error:
              diagnostics = {}
              properties = "-p MainPID -p ActiveState -p SubState -p Result "
              properties += "-p ExecMainCode -p ExecMainStatus -p ExecStart -p ExecStopPost"
              for label, diagnostic_command in (
                  ("controller-journal", "journalctl -u hermes-agent.service -u user@${toString uid}.service --no-pager -o cat -n 8"),
                  ("gateway-journal", "journalctl _SYSTEMD_USER_UNIT=hermes-gateway.service --no-pager -o cat -n 12"),
                  ("controller-status", "systemctl show hermes-agent.service user@${toString uid}.service " + properties),
                  ("gateway-status", "runuser -u hermes -- env XDG_RUNTIME_DIR=/run/user/${toString uid} "
                   "systemctl --user show hermes-gateway.service " + properties),
                  ("worker-state", "${pkgs.python3}/bin/python3 ${./diagnostics.py} ${home}"),
              ):
                  try:
                      diagnostics[label] = c(diagnostic_command)
                  except Exception as collection_error:
                      diagnostics[label] = f"diagnostic collection failed: {collection_error}"
              # Keep every source visible in Nix's last-25-lines failure summary.
              raise AssertionError(json.dumps({"error": str(error), "diagnostics": diagnostics})) from error

      def wait_for_worker_file(path, timeout):
          wait_for_worker_command(
              "systemd-run --machine=hermes --wait --quiet ${pkgs.coreutils}/bin/test -f " + path,
              timeout=timeout,
          )

      def gateway_property(name):
          return user("systemctl --user show hermes-gateway.service -p " + name + " --value")

      def gateway_ready():
          wait_for_worker_command(
              "systemd-run --machine=hermes --wait --quiet "
              "runuser -u hermes -- env XDG_RUNTIME_DIR=/run/user/${toString uid} "
              "systemctl --user is-active hermes-gateway.service",
              timeout=60,
          )
          invocation = gateway_property("InvocationID")
          assert len(invocation) == 32, invocation
          directory = "${home}/gateway-starts/" + invocation
          wait_for_worker_file(directory + "/started.json", timeout=60)
          # The exec shim removed the previous marker before this invocation.
          # Pinned scheduler_provider writes its first heartbeat AFTER recovery.
          wait_for_worker_file("${home}/cron/ticker_heartbeat", timeout=60)
          started = json.loads(c("cat " + directory + "/started.json"))
          assert started["pid"] == int(gateway_property("MainPID")), started
          assert started["invocation"] == invocation, started
          assert invocation != c("systemctl show hermes-agent.service -p InvocationID --value")
          return started, directory

      def ledger_status(expected):
          query = "import sqlite3; db=sqlite3.connect('file:${home}/cron/executions.db?mode=ro', uri=True); "
          query += "rows=db.execute('select status from executions').fetchall(); "
          query += "assert rows == [(" + repr(expected) + ",)], rows"
          return "${python} -c " + shlex.quote(query)

      def ledger_owner():
          query = "import json, runpy; from pathlib import Path; "
          query += "shim=runpy.run_path('${./gateway.py}'); "
          query += "print(json.dumps(shim['running_owner'](Path('${home}'))))"
          return json.loads(c("${python} -c " + shlex.quote(query)))

      def assert_recovery_identity(started, expected_owner):
          # Only read the ledger and validate G2's recorded evidence here. Never
          # run local_identity/get_identity from this unconfined test driver.
          query = "import runpy; from pathlib import Path; "
          query += "shim=runpy.run_path('${./gateway.py}'); "
          query += "owner=shim['running_owner'](Path('${home}')); "
          query += "assert owner == " + repr(expected_owner) + ", owner; "
          query += "shim['assert_recovery_identity'](" + repr(started['recovery_identity']) + ", owner)"
          c("${python} -c " + shlex.quote(query))

      def assert_cgroup_denied(result):
          assert set(result["cgroup_write_errnos"]) == {"cgroup.procs", "cgroup.subtree_control"}, result
          assert all(value in (errno.EACCES, errno.EPERM, errno.EROFS)
                     for value in result["cgroup_write_errnos"].values()), result

      def peer_control():
          current = json.loads(user("${pkgs.python3}/bin/python3 ${./peer.py} check "
                                    "/srv/worker-canary /run/hermes-test-peer/ready.json"))
          assert current == peer_fixture, (current, peer_fixture)
          assert c("systemctl show test-peer.service -p MainPID --value") == str(current["pid"])

      def cgroup_control():
          control = json.loads(user("systemd-run --user --wait --pipe --collect --quiet "
                                    "${python} ${./probe.py} cgroup-control"))
          assert control == {"cgroup.procs": 0, "cgroup.subtree_control": 0}, control

      @contextmanager
      def checked_probe(directory, *, cgroup_writes=False):
          peer_control()
          if cgroup_writes:
              cgroup_control()
          try:
              yield
          finally:
              peer_control()
              if cgroup_writes:
                  cgroup_control()
          result = report(directory() if callable(directory) else directory)
          assert result["peer_fixture"] == peer_fixture, result
          assert result["pid_namespace"] == peer_fixture["pid_namespace"], result
          pid = peer_fixture["pid"]
          assert set(result["proc_peer_errnos"]) == {
              f"/proc/{pid}/root/srv/worker-canary",
              f"/proc/{pid}/cwd/worker-canary", f"/proc/{pid}/fd/3",
          }, result
          assert all(value in (errno.EACCES, errno.EPERM, errno.ENOENT)
                     for value in result["proc_peer_errnos"].values()), result

      start_all()
      machine.wait_for_unit("container@hermes.service")
      machine.wait_until_succeeds(
          "systemctl --machine=hermes is-active hermes-agent.service user@${toString uid}.service"
      )
      c("test -S /run/user/${toString uid}/systemd/private")
      c("test ! -e /bin/true")
      manager = c("systemctl show user@${toString uid}.service -p MainPID --value")
      assert c(f"readlink /proc/{manager}/ns/cgroup") != c("readlink /proc/1/ns/cgroup")
      machine.wait_until_succeeds(
          "systemd-run --machine=hermes --wait --quiet ${pkgs.coreutils}/bin/test "
          "-f /run/hermes-test-peer/ready.json"
      )
      peer_fixture = json.loads(c("cat /run/hermes-test-peer/ready.json"))
      c("mkdir -p ${home}/scripts")
      c("cp ${./probe.py} ${home}/scripts/probe.py; cp ${./worker.py} ${home}/scripts/worker.py")
      c("chown -R hermes:hermes ${home}/scripts")

      with subtest("static gateway is forked by the confined manager"):
          c("systemctl stop hermes-agent.service")
          assert gateway_property("ActiveState") == "inactive"
          assert gateway_property("MainPID") == "0"
          assert gateway_property("UnitFileState") == "static"
          assert gateway_property("Restart") == "no"
          assert "ConditionUser=hermes" in user("systemctl --user cat hermes-gateway.service")
          user("touch ${home}/probe-gateway")
          with checked_probe(lambda: gateway_directory, cgroup_writes=True):
              c("systemctl start hermes-agent.service")
              gateway_started, gateway_directory = gateway_ready()
          assert gateway_started["recovery_identity"] == {"owner": None}, gateway_started
          gateway_pid = str(gateway_started["pid"])
          assert gateway_pid != c("systemctl show hermes-agent.service -p MainPID --value")
          status = dict(line.split(":", 1) for line in gateway_started["status"].splitlines())
          assert status["PPid"].strip() == manager, status
          assert status["Umask"].strip() == "0007", status
          assert gateway_started["cwd"] == "/var/lib/hermes/workspace"
          env = gateway_started["environment"]
          assert env["HOME"] == "/var/lib/hermes" and env["HERMES_HOME"] == "${home}", env
          assert env["HERMES_MANAGED"] == "true", env
          assert env["XDG_RUNTIME_DIR"] == "/run/user/${toString uid}", env
          assert "${pkgs.hello}/bin" in env["PATH"].split(":"), env
          assert "hermes-gateway.service" in gateway_started["cgroup"], gateway_started
          assert c(f"readlink /proc/{gateway_pid}/ns/mnt") == c(f"readlink /proc/{manager}/ns/mnt")
          assert_cgroup_denied(report(gateway_directory))

      with subtest("installed CLI launcher supports pipes"):
          output = user('printf %s "" | /run/current-system/sw/bin/hermes --help')
          assert "usage: hermes" in output.lower(), output

      with subtest("installed CLI launcher supports a PTY"):
          output = user(
              "${pkgs.util-linux}/bin/script --quiet --return --command "
              + shlex.quote("test -t 0 && test -t 1 && exec /run/current-system/sw/bin/hermes --help")
              + " /dev/null < /dev/null"
          )
          assert "usage: hermes" in output.lower(), output

      with subtest("manager services cannot turn off inherited restrictions"):
          for name, properties in (
              ("normal", ""),
              ("relaxed", "-p NoNewPrivileges=no -p ProtectSystem=no -p ProtectHome=no "
               "-p RestrictNamespaces=no -p ProtectControlGroups=no -p SystemCallFilter= "
               "-p CapabilityBoundingSet=~"),
          ):
              destination = "${home}/" + name
              with checked_probe(destination):
                  user(f"systemd-run --user --wait --pipe --collect --unit={name} {properties} "
                       f"-- ${python} ${./probe.py} /srv/worker-canary {destination}")
              assert report(destination)["outside_write_denied"]

      with subtest("user-authored privileged exec prefix stays constrained"):
          unit = "[Service]\nType=oneshot\nNoNewPrivileges=no\nProtectSystem=no\n"
          unit += "ExecStart=+${python} ${./probe.py} /srv/worker-canary ${home}/prefix\n"
          user("mkdir -p /var/lib/hermes/.config/systemd/user")
          user("printf %s " + shlex.quote(unit) + " > /var/lib/hermes/.config/systemd/user/prefix.service")
          with checked_probe("${home}/prefix"):
              user("systemctl --user daemon-reload; systemctl --user start prefix.service")
          assert report("${home}/prefix")["capabilities_empty"]

      with subtest("real scheduled cron survives gateway restart"):
          with checked_probe("${home}", cgroup_writes=True):
              user("${python} ${./seed.py}")
              wait_for_worker_file("${home}/worker-ready", timeout=180)
          worker_pid = c("cat ${home}/worker-ready")
          before = report("${home}")
          assert before["pid"] == int(worker_pid)
          assert_cgroup_denied(before)
          scope_names = [part for part in before["cgroup"].strip().split("/")
                         if part.startswith("hermes-worker-cron-") and part.endswith(".scope")]
          assert len(scope_names) == 1, before
          scope = scope_names[0]
          scope_cgroup = user(f"systemctl --user show {scope} -p ControlGroup --value")
          assert before["cgroup"].strip() == "0::" + scope_cgroup, (before, scope_cgroup)
          assert "hermes-gateway.service" not in scope_cgroup, scope_cgroup
          assert scope_cgroup.rsplit("/", 1)[0] == gateway_started["cgroup"].strip().rsplit("/", 1)[0].removeprefix("0::")
          c(ledger_status("running"))
          execution_owner = ledger_owner()
          assert execution_owner is not None
          # The external scheduler owns the execution; worker-ready is its child.
          assert execution_owner["pid"] != int(worker_pid), execution_owner
          for action in ("restart", "kill-controller", "restart"):
              previous = gateway_property("MainPID")
              controller = c("systemctl show hermes-agent.service -p MainPID --value")
              with checked_probe(lambda: gateway_directory, cgroup_writes=True):
                  if action == "kill-controller":
                      c("systemctl kill --kill-whom=main --signal=KILL hermes-agent.service")
                      machine.wait_until_succeeds(
                          "systemd-run --machine=hermes --wait --quiet ${pkgs.bash}/bin/bash -c "
                          + shlex.quote("test $(systemctl show hermes-agent.service -p MainPID --value) -gt 0 && "
                                        "test $(systemctl show hermes-agent.service -p MainPID --value) != " + controller)
                      )
                  else:
                      c("systemctl restart hermes-agent.service")
                  gateway_started, gateway_directory = gateway_ready()
              assert str(gateway_started["pid"]) != previous
              c(f"test ! -d /proc/{previous} && test -d /proc/{worker_pid}")
              assert c("systemctl show user@${toString uid}.service -p MainPID --value") == manager
              assert user(f"systemctl --user is-active {scope}") == "active"
              assert user(f"systemctl --user show {scope} -p ControlGroup --value") == scope_cgroup
              # gateway_ready waited for THIS invocation's post-recovery heartbeat.
              # Retention alone passes even if every manager probe returns unknown.
              c(ledger_status("running"))
              assert_recovery_identity(gateway_started, execution_owner)
              c("test ! -e ${home}/completions && test ! -e ${home}/release-worker")
              assert_cgroup_denied(report(gateway_directory))
          with checked_probe("${home}", cgroup_writes=True):
              c("touch ${home}/release-worker")
              wait_for_worker_file("${home}/completions", timeout=60)
          assert report("${home}")["pid"] == int(worker_pid)
          assert_cgroup_denied(report("${home}"))
          assert c("cat ${home}/completions") == "completed"
          machine.wait_until_succeeds(
              "systemd-run --machine=hermes --wait --pipe --quiet ${pkgs.bash}/bin/bash -c "
              + shlex.quote(ledger_status("completed")), timeout=60,
          )

      with subtest("manager reexecution retains enforcement"):
          with checked_probe("${home}/reexec"):
              user("systemctl --user daemon-reexec")
              user("systemd-run --user --wait --pipe --collect -- ${python} ${./probe.py} "
                   "/srv/worker-canary ${home}/reexec")
          assert report("${home}/reexec")["no_new_privileges"]

      with subtest("failed gateway launch fails the controller and still cleans up"):
          c("systemctl stop hermes-agent.service")
          old_manager = c("systemctl show user@${toString uid}.service -p MainPID --value")
          override = "[Service]\nRestart=no\n"
          c("mkdir -p /run/systemd/system/hermes-agent.service.d")
          c("printf %s " + shlex.quote(override) + " > /run/systemd/system/hermes-agent.service.d/test.conf")
          c("systemctl daemon-reload")
          user("mkdir -p /run/user/${toString uid}/systemd/user/hermes-gateway.service.d")
          broken = "[Service]\nExecStart=\nExecStart=/definitely-missing-hermes-gateway\n"
          user("printf %s " + shlex.quote(broken)
               + " > /run/user/${toString uid}/systemd/user/hermes-gateway.service.d/test.conf")
          user("systemctl --user daemon-reload")
          # Type=exec on the controller is not gateway/application readiness.
          c("systemctl start --no-block hermes-agent.service")
          machine.wait_until_succeeds("systemctl --machine=hermes is-failed hermes-agent.service")
          assert c("systemctl show hermes-agent.service -p Result --value") == "exit-code"
          assert gateway_property("MainPID") == "0"
          cleanup = c("systemctl show hermes-agent.service -p ExecStopPost --value")
          assert "status=0/SUCCESS" in cleanup, cleanup
          assert c("systemctl show user@${toString uid}.service -p MainPID --value") == old_manager
          user("rm /run/user/${toString uid}/systemd/user/hermes-gateway.service.d/test.conf; "
               "systemctl --user daemon-reload; systemctl --user reset-failed hermes-gateway.service")
          c("rm /run/systemd/system/hermes-agent.service.d/test.conf; "
            "systemctl daemon-reload; systemctl reset-failed hermes-agent.service")
          with checked_probe(lambda: gateway_directory, cgroup_writes=True):
              c("systemctl start hermes-agent.service")
              gateway_started, gateway_directory = gateway_ready()

      with subtest("explicit stop synchronously removes only the gateway"):
          previous = gateway_property("MainPID")
          c("systemctl stop hermes-agent.service")
          assert gateway_property("ActiveState") == "inactive"
          assert gateway_property("MainPID") == "0"
          c(f"test ! -d /proc/{previous}")
          assert c("systemctl show user@${toString uid}.service -p MainPID --value") == manager
          assert c("systemctl is-active user@${toString uid}.service") == "active"
          with checked_probe("${home}/after-stop"):
              user("systemd-run --user --wait --pipe --collect -- ${python} ${./probe.py} "
                   "/srv/worker-canary ${home}/after-stop")
          c(ledger_status("completed"))
          assert c("cat ${home}/completions") == "completed"

      c("journalctl -u hermes-agent.service -u user@${toString uid}.service --no-pager")
    '';
  }
