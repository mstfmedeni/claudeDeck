#!/usr/bin/env python3
"""A stand-in ServerPlan panel (agent API v1) for tools/demo.sh and manual testing.

    tools/serverplan-mock.py --port 5099 --token spk_1_demo --root /tmp/ClaudeDeckDemo

Serves the fixtures in Tests/ClaudeDeckCoreTests/Fixtures/serverplan (made-up servers and projects;
"/tmp/ClaudeDeckDemo/" in them becomes --root), answers destructive actions with 428 until they
carry the right "confirm", plays a deploy on POST …/deploy, streams events and logs over SSE, and
gives terminal tickets whose WebSocket runs a local /bin/sh in a scratch folder (no SSH anywhere).
`POST /_demo/fail` (no auth) emits a deploy.failed event, for the notification path.
Python standard library only.
"""
import argparse
import base64
import hashlib
import json
import os
import pty
import queue
import re
import secrets
import select
import signal
import struct
import fcntl
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "..", "Tests", "ClaudeDeckCoreTests", "Fixtures", "serverplan")
BASE = "/api/v1/agent"

args = None
state_lock = threading.Lock()
deployments = {}      # id -> deployment dict (with log)
deploy_lines = {}     # id -> list of log lines
deploy_done = {}      # id -> bool
tickets = {}          # ticket -> (server_id, command, expires)
subscribers = []      # queues of /events listeners
event_id = [100]


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        text = f.read()
    return json.loads(text.replace("/tmp/ClaudeDeckDemo/", args.root.rstrip("/") + "/"))


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def emit(kind, data):
    with state_lock:
        event_id[0] += 1
        eid = event_id[0]
        for q in subscribers:
            q.put((eid, kind, {"type": kind, "at": now(), "data": data}))


def load_state():
    for d in fixture("deployments.json"):
        deployments[d["id"]] = d
    full = fixture("deployment-207.json")
    deployments[207] = full
    deploy_lines[207] = full["log"].rstrip("\n").split("\n")
    deploy_done[207] = True
    deploy_lines[205] = ["[deploy] acme-storefront:205 running"]
    deploy_done[205] = True
    deploy_lines[208] = ["[git_pull] Already up to date.", "[build] Step 3/7 : RUN npm ci"]
    deploy_done[208] = False
    # Times relative to now, so the sidebar reads "25 min ago" rather than a fixed date.
    for dep_id, started, finished in ((207, 27, 25), (205, 102, 100), (208, 2, None)):
        deployments[dep_id]["started_at"] = ago(started)
        deployments[dep_id]["finished_at"] = ago(finished) if finished is not None else None


def ago(minutes):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - minutes * 60))


def play_deploy(dep_id, project, server):
    steps = [("building", "git_pull", "[git_pull] Already up to date."),
             ("building", "build", "[build] Step 1/7 : FROM node:22-alpine"),
             ("building", "build", "[build] Step 7/7 : RUN npm run build"),
             ("transferring", "transfer", "[transfer] image.tar 84 MB → %s" % server),
             ("deploying", "deploy", "[deploy] docker load && docker run --name %s" % project),
             ("success", "deploy", "[deploy] %s is running" % project)]
    emit("deploy.started", {"id": dep_id, "project_id": deployments[dep_id]["project_id"], "project_name": project,
                            "server_name": server, "status": "pending"})
    for status, step, line in steps:
        time.sleep(1.5)
        with state_lock:
            deployments[dep_id]["status"] = status
            deployments[dep_id]["step"] = step
            deploy_lines[dep_id].append(line)
    with state_lock:
        deployments[dep_id]["finished_at"] = now()
        deploy_done[dep_id] = True
    emit("deploy.succeeded", {"id": dep_id, "project_id": deployments[dep_id]["project_id"], "project_name": project,
                              "server_name": server, "status": "success"})


# --- WebSocket (RFC 6455, just enough) ---------------------------------------------------------

def ws_accept(key):
    return base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()


def ws_send(sock, opcode, payload):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + struct.pack(">H", n)
    else:
        header += bytes([127]) + struct.pack(">Q", n)
    sock.sendall(header + payload)


def ws_read(sock):
    def exact(n):
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data
    b1, b2 = exact(2)
    opcode = b1 & 0x0F
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", exact(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", exact(8))[0]
    mask = exact(4) if b2 & 0x80 else b"\0\0\0\0"
    data = bytes(c ^ mask[i % 4] for i, c in enumerate(exact(n)))
    return opcode, data


def terminal_session(sock, server_name, command):
    home = os.path.join(args.root, "serverplan", "servers", server_name)
    os.makedirs(home, exist_ok=True)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(home)
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "HOME": home, "LANG": "en_US.UTF-8",
               "PS1": "deploy@%s:~$ " % server_name}
        if command == "claude" and args.claude:
            os.execve(args.claude, [args.claude], env)
        os.write(1, ("Demo terminal for %s (a local shell in %s; no SSH)\r\n" % (server_name, home)).encode())
        os.execve("/bin/sh", ["/bin/sh", "-i"], env)
    try:
        while True:
            ready, _, _ = select.select([sock, fd], [], [], 30)
            if fd in ready:
                try:
                    out = os.read(fd, 65536)
                except OSError:
                    out = b""
                if not out:
                    break
                ws_send(sock, 0x2, out)
            if sock in ready:
                opcode, data = ws_read(sock)
                if opcode == 0x8:
                    break
                if opcode == 0x2:
                    os.write(fd, data)
                elif opcode == 0x1:
                    msg = json.loads(data.decode() or "{}")
                    if msg.get("type") == "resize":
                        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", msg["rows"], msg["cols"], 0, 0))
                elif opcode == 0x9:
                    ws_send(sock, 0xA, data)
    except (EOFError, ConnectionError, OSError):
        pass
    finally:
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
            code = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            code = 0
        try:
            ws_send(sock, 0x1, json.dumps({"type": "exit", "code": code}).encode())
            ws_send(sock, 0x8, struct.pack(">H", 1000))
        except OSError:
            pass


# --- HTTP ---------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        if args.verbose:
            super().log_message(fmt, *a)

    def send_json(self, status, obj, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, code, message, **extra):
        self.send_json(status, dict({"error": code, "message": message}, **extra))

    def authed(self):
        if self.headers.get("Authorization") != "Bearer " + args.token:
            self.error(401, "unauthorized", "Geçersiz veya iptal edilmiş token")
            return False
        return True

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def sse_start(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def sse(self, event, data, eid=None):
        text = ""
        if eid is not None:
            text += "id: %s\n" % eid
        text += "event: %s\ndata: %s\n\n" % (event, json.dumps(data))
        self.wfile.write(text.encode())
        self.wfile.flush()

    # GET
    def do_GET(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        if path == BASE + "/ws/terminal":
            return self.websocket(query)
        if not path.startswith(BASE) or not self.authed():
            if not path.startswith(BASE):
                self.error(404, "not_found", "Bulunamadı")
            return
        p = path[len(BASE):]
        try:
            if p == "/me":
                return self.send_json(200, fixture("me.json"))
            if p == "/servers":
                return self.send_json(200, fixture("servers.json"))
            m = re.fullmatch(r"/servers/(\d+)/health", p)
            if m:
                sid = int(m.group(1))
                if sid == 3:
                    return self.send_json(200, fixture("health-unreachable.json"))
                h = fixture("health-1.json")
                if sid == 2:
                    h.update(cpu="1.3%", memory="0.6Gi/2.0Gi", disk="9G/40G (22%)", uptime="up 30 days")
                return self.send_json(200, h)
            m = re.fullmatch(r"/servers/(\d+)/capabilities", p)
            if m:
                sid = int(m.group(1))
                return self.send_json(200, {"claude": sid == 1, "claude_path": "/usr/local/bin/claude" if sid == 1 else None, "checked_at": now()})
            if p == "/projects":
                projects = fixture("projects.json")
                with state_lock:
                    for pr in projects:
                        latest = max((d for d in deployments.values() if d["project_id"] == pr["id"]), key=lambda d: d["id"], default=None)
                        if latest:
                            pr["last_deploy"] = {"id": latest["id"], "status": latest["status"], "finished_at": latest.get("finished_at")}
                return self.send_json(200, projects)
            m = re.fullmatch(r"/servers/(\d+)/containers", p)
            if m:
                name = "containers-%s.json" % m.group(1)
                return self.send_json(200, fixture(name) if os.path.exists(os.path.join(FIXTURES, name)) else [])
            if p == "/deployments":
                limit = int(query.get("limit", ["20"])[0])
                with state_lock:
                    items = sorted(deployments.values(), key=lambda d: -d["id"])
                    items = [{k: v for k, v in d.items() if k != "log"} for d in items]
                return self.send_json(200, items[:limit])
            m = re.fullmatch(r"/deployments/(\d+)", p)
            if m:
                with state_lock:
                    d = deployments.get(int(m.group(1)))
                    if d:
                        d = dict(d, log="\n".join(deploy_lines.get(d["id"], [])))
                return self.send_json(200, d) if d else self.error(404, "not_found", "Deploy bulunamadı")
            m = re.fullmatch(r"/deployments/(\d+)/stream", p)
            if m:
                return self.deploy_stream(int(m.group(1)))
            m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/logs", p)
            if m:
                text = "\n".join("2026-11-18T09:%02d:00Z %s | request %d ok" % (i % 60, unquote(m.group(2)), i) for i in range(40))
                body = text.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return self.wfile.write(body)
            m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/logs/stream", p)
            if m:
                return self.log_stream(unquote(m.group(2)))
            if p == "/events":
                return self.events()
            self.error(404, "not_found", "Bulunamadı")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def deploy_stream(self, dep_id):
        with state_lock:
            if dep_id not in deployments:
                return self.error(404, "not_found", "Deploy bulunamadı")
        self.sse_start()
        sent = 0
        last_status = None
        last_ping = time.time()
        while True:
            with state_lock:
                lines = list(deploy_lines.get(dep_id, []))
                d = dict(deployments[dep_id])
                done = deploy_done.get(dep_id, True)
            for line in lines[sent:]:
                self.sse("log", {"line": line})
            sent = len(lines)
            if (d["status"], d.get("step")) != last_status:
                last_status = (d["status"], d.get("step"))
                self.sse("status", {"status": d["status"], "step": d.get("step")})
            if done:
                self.sse("done", dict(d, log="\n".join(lines)))
                return
            if time.time() - last_ping > 25:
                self.wfile.write(b": ping\n\n")
                self.wfile.flush()
                last_ping = time.time()
            time.sleep(0.3)

    def log_stream(self, container):
        self.sse_start()
        if container == "payments-api":  # exited container: the tail, then docker logs ends
            for line in deploy_lines.get(207, [])[-3:]:
                self.sse("log", {"line": line, "stream": "stderr"})
            self.sse("end", {"reason": "log stream ended"})
            return
        i = 0
        while True:
            self.sse("log", {"line": "%s %s | GET /health 200 %dms" % (now(), container, 2 + i % 5), "stream": "stdout"})
            i += 1
            time.sleep(2)

    def events(self):
        q = queue.Queue()
        with state_lock:
            subscribers.append(q)
        try:
            self.sse_start()
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while True:
                try:
                    eid, kind, data = q.get(timeout=25)
                    self.sse(kind, data, eid)
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
        finally:
            with state_lock:
                subscribers.remove(q)

    def websocket(self, query):
        ticket = (query.get("ticket") or [""])[0]
        with state_lock:
            entry = tickets.pop(ticket, None)
        if not entry or entry[2] < time.time() or self.headers.get("Upgrade", "").lower() != "websocket":
            return self.error(401, "unauthorized", "Bilet geçersiz veya süresi dolmuş")
        server_id, command, _ = entry
        name = next((s["name"] for s in fixture("servers.json") if s["id"] == server_id), "server")
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", ws_accept(self.headers["Sec-WebSocket-Key"]))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        terminal_session(self.connection, name, command)

    # POST
    def do_POST(self):
        url = urlparse(self.path)
        if url.path == "/_demo/fail":
            # A new failed deploy of payments-api (a new id, so it notifies once).
            with state_lock:
                dep_id = max(deployments) + 1
                deployments[dep_id] = dict(deployments[207], id=dep_id, started_at=ago(1), finished_at=now())
                deploy_lines[dep_id] = list(deploy_lines[207])
                deploy_done[dep_id] = True
            emit("deploy.failed", {"id": dep_id, "project_id": 11, "project_name": "payments-api", "server_id": 1,
                                   "server_name": "prod-eu-1", "status": "failed", "error": deployments[207]["error"]})
            return self.send_json(200, {"ok": True, "deployment_id": dep_id})
        if not url.path.startswith(BASE) or not self.authed():
            if not url.path.startswith(BASE):
                self.error(404, "not_found", "Bulunamadı")
            return
        p = url.path[len(BASE):]
        body = self.body()
        if p == "/ws-ticket":
            sid = int(body.get("server_id", 0))
            command = body.get("command", "shell")
            if command == "claude" and sid != 1:
                return self.error(400, "bad_request", "Bu sunucuda claude yok")
            ticket = secrets.token_urlsafe(24)
            with state_lock:
                tickets[ticket] = (sid, command, time.time() + 60)
            return self.send_json(200, {"ticket": ticket, "expires_in": 60, "url": BASE + "/ws/terminal?ticket=" + ticket})
        m = re.fullmatch(r"/projects/(\d+)/deploy", p)
        if m:
            pid = int(m.group(1))
            project = next((pr for pr in fixture("projects.json") if pr["id"] == pid), None)
            if not project:
                return self.error(404, "not_found", "Proje bulunamadı")
            servers = {s["id"]: s["name"] for s in fixture("servers.json")}
            server = servers.get(body.get("server_id") or project["default_server_id"], "?")
            name = project["display_name"]
            if body.get("confirm") != name:
                rebuild = " (imaj sıfırdan derlenir)" if body.get("force_rebuild") else ""
                return self.error(428, "confirm_required", "Bu işlem onay gerektirir",
                                  summary="%s → %s: imaj derlenir%s, SSH ile aktarılır ve çalışan %s konteyneri yenisiyle değiştirilir."
                                  % (name, server, rebuild, name), confirm=name)
            with state_lock:
                dep_id = max(deployments) + 1
                deployments[dep_id] = {"id": dep_id, "project_id": pid, "project_name": name, "server_id": project["default_server_id"],
                                       "server_name": server, "status": "pending", "step": "git_pull", "error": None, "branch": project["branch"],
                                       "commit": None, "started_at": now(), "finished_at": None}
                deploy_lines[dep_id] = []
                deploy_done[dep_id] = False
            threading.Thread(target=play_deploy, args=(dep_id, name, server), daemon=True).start()
            return self.send_json(202, {"deployment_id": dep_id, "stream_url": "%s/deployments/%d/stream" % (BASE, dep_id)})
        m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/(start|stop|restart)", p)
        if m:
            name, verb = unquote(m.group(2)), m.group(3)
            if body.get("confirm") != name:
                words = {"start": "başlatılır", "stop": "durdurulur", "restart": "yeniden başlatılır"}
                return self.error(428, "confirm_required", "Bu işlem onay gerektirir",
                                  summary="%s konteyneri %s." % (name, words[verb]), confirm=name)
            return self.send_json(200, {"ok": True})
        self.error(404, "not_found", "Bulunamadı")


def main():
    global args
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=5099)
    parser.add_argument("--token", default="spk_1_demo")
    parser.add_argument("--root", default="/tmp/ClaudeDeckDemo")
    parser.add_argument("--claude", default=None, help="what a 'claude' terminal runs (the demo stand-in)")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.port == 5050:
        raise SystemExit("refusing :5050 (the real panel's port)")
    load_state()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print("ServerPlan mock on http://127.0.0.1:%d (token %s)" % (args.port, args.token), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
