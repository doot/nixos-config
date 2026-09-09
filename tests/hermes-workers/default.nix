{
  pkgs,
  inputs,
}: let
  package = import ../../systems/nix-slopfucker/hermes-package.nix {
    inherit pkgs;
    inherit (inputs) hermes-agent;
  };
  python = "${package.hermesVenv}/bin/python3";
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
            inherit package;
            settings = {
              terminal.cwd = "/var/lib/hermes/workspace";
              cron.script_timeout_seconds = 180;
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

      def wait_for_worker_file(path, timeout):
          try:
              machine.wait_until_succeeds(
                  "systemd-run --machine=hermes --wait --quiet ${pkgs.coreutils}/bin/test -f " + path,
                  timeout=timeout,
              )
          except Exception as error:
              diagnostics = []
              for command in (
                  "journalctl -u hermes-agent.service -u user@${toString uid}.service --no-pager -o cat -n 8",
                  "${pkgs.python3}/bin/python3 ${./diagnostics.py} ${home}",
              ):
                  try:
                      diagnostics.append(c(command))
                  except Exception as collection_error:
                      diagnostics.append(f"diagnostic collection failed: {collection_error}")
              raise AssertionError(str(error) + "\n" + "\n".join(diagnostics)) from error

      def peer_control():
          current = json.loads(user("${pkgs.python3}/bin/python3 ${./peer.py} check "
                                    "/srv/worker-canary /run/hermes-test-peer/ready.json"))
          assert current == peer_fixture, (current, peer_fixture)
          assert c("systemctl show test-peer.service -p MainPID --value") == str(current["pid"])

      @contextmanager
      def checked_probe(directory):
          peer_control()
          try:
              yield
          finally:
              peer_control()
          result = report(directory)
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
          with checked_probe("${home}"):
              user("${python} ${./seed.py}")
              wait_for_worker_file("${home}/worker-ready", timeout=180)
          worker_pid = c("cat ${home}/worker-ready")
          before = report("${home}")
          assert before["pid"] == int(worker_pid)
          assert "hermes-worker-cron-" in before["cgroup"], before
          with checked_probe("${home}"):
              gateway = c("systemctl show hermes-agent.service -p MainPID --value")
              c("systemctl restart hermes-agent.service")
              assert c("systemctl show hermes-agent.service -p MainPID --value") != gateway
              assert c("systemctl show user@${toString uid}.service -p MainPID --value") == manager
              c(f"test -d /proc/{worker_pid}")
              c("touch ${home}/release-worker")
              wait_for_worker_file("${home}/completions", timeout=60)
          assert report("${home}")["pid"] == int(worker_pid)
          assert c("cat ${home}/completions") == "completed"
          query = "import sqlite3; db=sqlite3.connect('${home}/cron/executions.db'); "
          query += "rows=db.execute('select status from executions').fetchall(); "
          query += "assert rows == [('completed',)], rows"
          machine.wait_until_succeeds(
              "systemd-run --machine=hermes --wait --pipe --quiet ${python} -c " + shlex.quote(query),
              timeout=60,
          )

      with subtest("manager reexecution retains enforcement"):
          with checked_probe("${home}/reexec"):
              user("systemctl --user daemon-reexec")
              user("systemd-run --user --wait --pipe --collect -- ${python} ${./probe.py} "
                   "/srv/worker-canary ${home}/reexec")
          assert report("${home}/reexec")["no_new_privileges"]

      c("journalctl -u hermes-agent.service -u user@${toString uid}.service --no-pager")
    '';
  }
