"""Exercise the evaluated nginx vhosts with public dummy credentials and a local backend."""

import base64
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time

HOST = "hermes.nmd.jhauschildt.com"
PASSWORD = "public-test-password-not-a-production-credential"
BASIC = "Basic " + base64.b64encode(f"admin:{PASSWORD}".encode()).decode()
SETTINGS = json.loads(os.environ["TEST_CONFIG"])
COMMAND = shlex.split(SETTINGS["command"])
SOURCE = Path(COMMAND[COMMAND.index("-c") + 1]).read_text()
assert SETTINGS["upstream"].startswith("http://unix:"), "nginx still trusts an unprivileged TCP listener"
tunnel = SETTINGS["tunnel"]
assert tunnel["DynamicUser"] and tunnel["RuntimeDirectoryMode"] == "0750"
assert tunnel["Group"] in SETTINGS["nginxGroups"] and tunnel["Group"] != "nginx"
assert "StreamLocalBindMask=0117" in tunnel["ExecStart"]
assert "StreamLocalBindUnlink=yes" in tunnel["ExecStart"]
ROOT = Path(tempfile.mkdtemp(prefix="webapp-", dir=os.environ["TMPDIR"]))
ssh_command = [argument.replace("%d", str(ROOT / "unused-credentials")) for argument in shlex.split(tunnel["ExecStart"])]
ssh_policy = subprocess.check_output([ssh_command[0], "-G", *ssh_command[1:]], text=True)
ssh_settings = dict(line.split(" ", 1) for line in ssh_policy.splitlines() if " " in line)
socket_path = SETTINGS["upstream"].removeprefix("http://unix:").removesuffix(":")
assert ssh_settings["localforward"] == f"{socket_path} [10.100.0.2]:9120"
assert ssh_settings["stricthostkeychecking"] == "true"
assert ssh_settings["identityagent"] == "none" and ssh_settings["streamlocalbindmask"] == "0117"
assert ssh_settings["streamlocalbindunlink"] == "yes"


class Backend(http.server.BaseHTTPRequestHandler):
    """Return request headers or a minimal WebSocket handshake for regression assertions."""

    def do_GET(self) -> None:
        """Handle a fixture request without serving any application or production data."""
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            digest = hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
            self.end_headers()
            self.close_connection = True
            return
        body = json.dumps(dict(self.headers)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        """Suppress fixture request logging."""


class UnixBackend(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Serve the same fixture over a Unix socket."""

    daemon_threads = True


backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
unix_backend = UnixBackend(str(ROOT / "upstream.sock"), Backend)
for server in (backend, unix_backend):
    threading.Thread(target=server.serve_forever, daemon=True).start()
subprocess.run(
    [
        "openssl",
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-days",
        "1",
        "-subj",
        f"/CN={HOST}",
        "-addext",
        f"subjectAltName=DNS:{HOST}",
        "-keyout",
        str(ROOT / "dummy.key"),
        "-out",
        str(ROOT / "dummy.crt"),
    ],
    check=True,
    capture_output=True,
)
password_file = ROOT / "dummy.htpasswd"
password_file.write_text(subprocess.check_output(["htpasswd", "-niBC", "4", "admin"], input=PASSWORD + "\n", text=True))
reservations = [socket.socket(), socket.socket()]
for reservation in reservations:
    reservation.bind(("127.0.0.1", 0))
http_port, tls_port = [reservation.getsockname()[1] for reservation in reservations]
blocks = [
    match.group(0)
    for match in re.finditer(r"(?ms)^([ \t]*)server \{\n.*?^\1\}", SOURCE)
    if re.search(r"server_name\s+" + re.escape(HOST) + r"[ ;]", match.group(0))
]
assert len(blocks) == 2, f"Expected both Hermes vhosts, found {len(blocks)}"
rewritten = []
for block in blocks:
    tls = "ssl_certificate " in block
    block = re.sub(r"(?m)^\s*listen [^;]+;", "", block)
    block = block.replace("server {", f"server {{\nlisten 127.0.0.1:{tls_port if tls else http_port}" + (" ssl;" if tls else ";"), 1)
    for directive, name in (("ssl_certificate", "dummy.crt"), ("ssl_certificate_key", "dummy.key"), ("ssl_trusted_certificate", "dummy.crt")):
        block = re.sub(rf"{directive}\s+[^;]+;", f"{directive} {ROOT}/{name};", block)
    block = block.replace("/var/log/nginx/", str(ROOT) + "/")
    if SETTINGS["authFile"] is not None:
        block = block.replace(SETTINGS["authFile"], str(password_file))
    block = block.replace("http://127.0.0.1:9120", f"http://127.0.0.1:{backend.server_port}")
    block = re.sub(r"http://unix:[^;]+;", f"http://unix:{ROOT}/upstream.sock:;", block)
    rewritten.append(block)
log_format = re.search(r"log_format hermes_webapp[^;]+;", SOURCE)
assert log_format, "Missing credential-safe log format"
# PrivateDevices in the nginx unit denies device paths such as /dev/null.
for block in blocks:
    assert re.findall(r"error_log\s+([^;]+);", block) == ["stderr emerg"], "Request errors must stay unlogged without device paths"
origin_map = re.search(r"map\s+\$http_origin\s+\$hermes_webapp_origin_allowed\s*\{[^}]*\}", SOURCE)
config = ROOT / "nginx.conf"
config.write_text(f"""pid {ROOT}/nginx.pid;
error_log {ROOT}/global-error.log info;
daemon off;
master_process off;
events {{}}
http {{
access_log {ROOT}/default-access.log combined;
client_body_temp_path {ROOT}/client_temp;
proxy_temp_path {ROOT}/proxy_temp;
{log_format.group(0)}
map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
{origin_map.group(0) if origin_map else ""}
{chr(10).join(rewritten)}
}}
""")
command = ["nginx", "-p", str(ROOT), "-c", str(config)]
subprocess.run(command + ["-t"], check=True, capture_output=True)
for reservation in reservations:
    reservation.close()
context = ssl.create_default_context(cafile=str(ROOT / "dummy.crt"))


def _request(path: str = "/", headers: dict[str, str] | None = None, *, tls: bool = True, source: str = "127.0.0.1") -> tuple[int, dict[str, str], bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", tls_port if tls else http_port, timeout=5, source_address=(source, 0))
    # Use the deployed hostname for TLS without modifying the test host's resolver.
    if tls:
        raw = socket.create_connection(("127.0.0.1", tls_port), timeout=5, source_address=(source, 0))
        connection.sock = context.wrap_socket(raw, server_hostname=HOST)
    try:
        connection.request("GET", path, headers={"Host": HOST, **(headers or {})})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


with (ROOT / "process.log").open("w") as log:
    process = subprocess.Popen(command, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if process.poll() is not None:
                raise AssertionError((ROOT / "process.log").read_text())
            try:
                _request(tls=False)
                break
            except OSError:
                time.sleep(0.02)
        else:
            raise AssertionError("nginx did not start")
        status, _, _ = _request("/api/auth/me")
        assert status == 401, f"Independent password gate missing: anonymous request returned {status}"
        assert _request(headers={"Authorization": "Basic " + base64.b64encode(b"admin:wrong").decode()})[0] == 401
        assert _request(headers={"Authorization": BASIC}, source="127.0.0.2")[0] == 403, "Password must not bypass the client ACL"
        status, _, body = _request(
            headers={
                "Authorization": BASIC,
                "Proxy-Authorization": "dummy-proxy-secret",
                "Cookie": "dummy_app_cookie=fixture",
                "X-Forwarded-For": "192.168.1.1",
            }
        )
        assert status == 200, status
        forwarded = {name.lower(): value for name, value in json.loads(body).items()}
        assert "authorization" not in forwarded and "proxy-authorization" not in forwarded, forwarded
        assert forwarded["cookie"] == "dummy_app_cookie=fixture"
        assert forwarded["x-forwarded-proto"] == "https"
        assert forwarded["x-forwarded-for"] == "127.0.0.1"
        for origin in ("https://evil.example", "https://sibling.nmd.jhauschildt.com"):
            assert _request(headers={"Authorization": BASIC, "Origin": origin})[0] == 403
        ws_headers = {
            "Authorization": BASIC,
            "Origin": f"https://{HOST}",
            "Connection": "Upgrade",
            "Upgrade": "websocket",
            "Sec-WebSocket-Version": "13",
            "Sec-WebSocket-Key": base64.b64encode(bytes(range(16))).decode(),
        }
        assert _request("/api/ws?ticket=DUMMY_QUERY_MARKER", ws_headers)[0] == 101
        assert _request("/api/ws", {name: value for name, value in ws_headers.items() if name != "Authorization"})[0] == 401
        assert _request("/api/ws", {**ws_headers, "Origin": "https://evil.example"})[0] == 403
        assert _request("/?ticket=DUMMY_QUERY_MARKER", tls=False)[0] == 308
        password_file.rename(ROOT / "unavailable.htpasswd")
        missing_status = _request(headers={"Authorization": BASIC})[0]
        assert missing_status == 403, f"Missing password file returned {missing_status}"
        password_file.write_text("")
        assert _request(headers={"Authorization": BASIC})[0] == 401, "Empty password file must fail closed"
    finally:
        process.terminate()
        process.wait(timeout=5)
        for server in (backend, unix_backend):
            server.shutdown()
            server.server_close()
logs = list(ROOT.glob("*.log"))
assert logs, "No nginx logs collected"
assert all("DUMMY_QUERY_MARKER" not in path.read_text() for path in logs), "Query credential leaked into a log"
print(f"PASS: independent password gate, credential stripping, WebSockets, Origin and fail-closed checks; fixture={ROOT}")
