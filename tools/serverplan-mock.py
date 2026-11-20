#!/usr/bin/env python3
"""A stand-in ServerPlan panel (agent API v1, and the v1.2 / v1.3 routes `claudedeck server` uses) for tools/demo.sh and manual testing.

    tools/serverplan-mock.py --port 5099 --token spk_1_demo --root /tmp/ClaudeDeckDemo

Serves the fixtures in Tests/ClaudeDeckCoreTests/Fixtures/serverplan (made-up servers and projects;
"/tmp/ClaudeDeckDemo/" in them becomes --root), answers destructive actions with 428 until they
carry the right "confirm", plays a deploy on POST …/deploy, streams events and logs over SSE, and
gives terminal tickets whose WebSocket runs a local /bin/sh in a scratch folder (no SSH anywhere).
`POST /_demo/fail` (no auth) emits a deploy.failed event, for the notification path.
`--v13` makes /me a 1.3 panel (domain check / purchase); `--purchase enabled` lets the mock "buy"
domains (nothing is registered anywhere; the default, like the panel's, refuses with 412).
`--v14` makes it a 1.4 panel: GET /registrar/balance (`--balance`, `--low-threshold`; `--namecheap
unconfigured` answers 412), the balance in /domains/check, and the edge-triggered registrar.low_balance /
registrar.balance_ok events. `POST /_demo/balance?value=N` (no auth) sets the balance, for the alert path.
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
        if command.startswith("exec:"):
            env["PS1"] = "root@%s:/app# " % command[5:]
            os.write(1, ("Demo shell in container %s on %s (a local shell; no docker exec)\r\n" % (command[5:], server_name)).encode())
            os.execve("/bin/sh", ["/bin/sh", "-i"], env)
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


# --- Agent API v1.2 (and env rescan) -----------------------------------------------------------
# Stand-ins for `claudedeck server sql | local | local-env | db clone-for-local | git | build |
# pull-deploy | diagnose | deploy-cancel | domain set/apply/nginx/purge | cloudflare purge/ssl |
# pg | server-env | env rescan | env rm`. Served always; `/me` offers them with --v12.

local_runs = {}       # project id -> {"status", "port", "started_at", "error"}
env_deleted = {}      # project id -> {env row ids removed with `env rm`}
local_env = {}        # project id -> {key: value}
clone_jobs = {}       # job id -> {"server_id", "source", "target", "started"}
server_env = {1: [("APP_REGION", "eu-central"), ("SENTRY_TOKEN", "x")], 2: [("APP_REGION", "eu-west")]}
pg_users = {1: [{"name": "appuser", "is_superuser": True, "databases": []}]}

MOCK_DOMAINS = [
    {"id": 5, "fqdn": "api.example.com", "subdomain": "api", "base_domain": "example.com", "type": "go_app", "target": "payments-api",
     "port": 8080, "server_id": 1, "project_name": "payments-api", "ssl_enabled": True, "clean_urls": False, "websocket_enabled": False},
    {"id": 6, "fqdn": "docs.example.com", "subdomain": "docs", "base_domain": "example.com", "type": "static",
     "target": "/opt/static/docs-example-com", "port": 0, "server_id": 2, "project_name": "", "ssl_enabled": True, "clean_urls": True,
     "websocket_enabled": False},
    # A root static site as quick-static stores it: subdomain "@".
    {"id": 7, "fqdn": "example.org", "subdomain": "@", "base_domain": "example.org", "type": "static",
     "target": "/opt/static/example-org", "port": 0, "server_id": 2, "project_name": "", "ssl_enabled": True, "clean_urls": True,
     "websocket_enabled": False},
    {"id": 8, "fqdn": "shop.acme.example", "subdomain": "shop", "base_domain": "acme.example", "type": "go_app", "target": "acme-storefront",
     "port": 3000, "server_id": 1, "project_name": "acme-storefront", "ssl_enabled": True, "clean_urls": False, "websocket_enabled": False},
]
SECRET_WORDS = ("PASSWORD", "SECRET", "KEY", "TOKEN", "PRIVATE", "CREDENTIAL")


def is_secret_name(key):
    return any(w in key.upper() for w in SECRET_WORDS)


def project_by_id(pid):
    return next((pr for pr in fixture("projects.json") if pr["id"] == pid), None)


def project_env_rows(pid):
    """The project's env rows (LOG_LEVEL twice, as after a double import), minus deleted ones."""
    rows = [{"id": 1, "key": "DB_NAME", "value": db_name(pid), "is_secret": False, "source": "auto-db"},
            {"id": 2, "key": "DB_PASSWORD", "value": None, "is_secret": True, "source": "auto-db"},
            {"id": 3, "key": "LOG_LEVEL", "value": "info", "is_secret": False, "source": "import"},
            {"id": 4, "key": "LOG_LEVEL", "value": "debug", "is_secret": False, "source": "manual"}]
    with state_lock:
        gone = set(env_deleted.get(pid, set()))
    return [r for r in rows if r["id"] not in gone]


def db_name(pid, local=False):
    if local and "DB_NAME" in local_env.get(pid, {}):
        return local_env[pid]["DB_NAME"]
    project = project_by_id(pid)
    return project["display_name"].replace("-", "_") if project else None


def single_statement(query):
    q = query.strip().rstrip(";").strip()
    if not q:
        return None, "sorgu bos"
    if ";" in q:
        return None, "tek seferde sadece bir SQL ifadesi calistirilabilir"
    if "\\" in q:
        return None, "psql meta komutlari (\\) kullanilamaz"
    return q, None


def finish_local_run(pid):
    time.sleep(3)
    with state_lock:
        run = local_runs.get(pid)
        if run and run["status"] == "building":
            run["status"] = "running"


def clone_job_view(job_id):
    job = clone_jobs[job_id]
    elapsed = time.time() - job["started"]
    steps = [("prepare", "Hedef veritabani olusturuluyor", 10), ("dump", "pg_dump | psql", 60), ("done", "Klonlama tamamlandi", 100)]
    events = [{"job_id": job_id, "step": s, "status": "success" if p == 100 else "running", "message": m, "progress": p}
              for i, (s, m, p) in enumerate(steps) if elapsed >= i * 1.5]
    status = "success" if elapsed >= 3 else "running"
    return {"id": job_id, "server_id": job["server_id"], "source": job["source"], "target": job["target"], "status": status, "events": events}


def send_text(h, text):
    body = text.encode()
    h.send_response(200)
    h.send_header("Content-Type", "text/plain; charset=utf-8")
    h.send_header("Content-Length", str(len(body)))
    h.end_headers()
    h.wfile.write(body)


def v12_get(h, p, query):
    """GET routes; True when handled."""
    if p == "/domains":
        sid = (query.get("server_id") or [""])[0]
        # Like the panel: the raw rows, without an `fqdn` (the client builds it; "@" is the root).
        h.send_json(200, [{k: v for k, v in d.items() if k != "fqdn"} for d in MOCK_DOMAINS if not sid or str(d["server_id"]) == sid])
        return True
    m = re.fullmatch(r"/projects/(\d+)/(settings|env|branches|local-status|local-logs|local-env)", p)
    if m:
        pid, what = int(m.group(1)), m.group(2)
        project = project_by_id(pid)
        if not project:
            h.error(404, "not_found", "Proje bulunamadi")
            return True
        branch = project.get("branch") or "main"
        if what == "settings":
            h.send_json(200, {"default_server_id": project["default_server_id"], "default_port": 8080, "volume_path": "",
                              "dockerfile_path": "Dockerfile", "env_vars": []})
        elif what == "env":
            h.send_json(200, project_env_rows(pid))
        elif what == "branches":
            h.send_json(200, {"branches": [branch, "develop"], "current_branch": branch})
        elif what == "local-status":
            with state_lock:
                run = dict(local_runs.get(pid) or {})
            if not run:
                h.send_json(200, {"running": False})
            else:
                h.send_json(200, dict(run, running=run["status"] in ("running", "building"), container_name="local-" + project["display_name"],
                                      db_host="10.0.0.5", db_source="server", local_url="http://localhost:%d" % run["port"]))
        elif what == "local-logs":
            with state_lock:
                run = local_runs.get(pid)
            if not run or run["status"] == "stopped":
                h.error(404, "not_found", "Proje lokalde calismiyor")
                return True
            tail = int((query.get("tail") or ["200"])[0])
            lines = ["%s local-%s | listening on :%d" % (now(), project["display_name"], run["port"])] + \
                    ["%s local-%s | GET /health 200" % (now(), project["display_name"])] * 5
            send_text(h, "\n".join(lines[-tail:]))
        else:
            with state_lock:
                env = dict(local_env.get(pid, {}))
            h.send_json(200, [{"key": k, "value": None if is_secret_name(k) else v, "is_secret": is_secret_name(k), "updated_at": now()}
                              for k, v in sorted(env.items())])
        return True
    m = re.fullmatch(r"/pg/clone-jobs/([A-Za-z0-9]+)", p)
    if m:
        with state_lock:
            view = clone_job_view(m.group(1)) if m.group(1) in clone_jobs else None
        if view is None:
            h.error(404, "not_found", "Klonlama isi bulunamadi")
        else:
            h.send_json(200, view)
        return True
    if p == "/cloudflare/ssl":
        domain = (query.get("domain") or [""])[0]
        if not domain:
            h.error(400, "bad_request", "domain parametresi gerekli")
        else:
            h.send_json(200, {"domain": domain, "ssl_mode": "full", "is_full": True})
        return True
    m = re.fullmatch(r"/servers/(\d+)/(pg/databases|pg/users|env)", p)
    if m:
        sid, what = int(m.group(1)), m.group(2)
        if what == "pg/databases":
            h.send_json(200, [{"name": pr["display_name"].replace("-", "_"), "owner": "appuser", "size": "%d MB" % (8 * pr["id"])}
                              for pr in fixture("projects.json") if pr["default_server_id"] == sid])
        elif what == "pg/users":
            h.send_json(200, pg_users.get(sid, []))
        else:
            h.send_json(200, [{"id": i + 1, "key": k, "value": None if is_secret_name(k) else v}
                              for i, (k, v) in enumerate(server_env.get(sid, []))])
        return True
    return False


def confirm_required(h, summary, want):
    h.error(428, "confirm_required", "Onay gerekli: confirm alanina hedefin tam adini yazin", summary=summary, confirm=want)
    return True


def v12_project_post(h, pid, what, body):
    project = project_by_id(pid)
    if not project:
        h.error(404, "not_found", "Proje bulunamadi")
        return True
    name = project["display_name"]
    if what == "env/rescan":
        h.send_json(200, {"dry_run": bool(body.get("dry_run")), "added": [{"key": "FEATURE_FLAGS", "is_secret": False},
                                                                           {"key": "STRIPE_SECRET", "is_secret": True}]})
    elif what == "sql":
        stmt, err = single_statement(body.get("query") or "")
        if err:
            h.error(400, "bad_request", err)
            return True
        db = db_name(pid, body.get("target") == "local")
        if body.get("write"):
            if body.get("confirm") != db:
                return confirm_required(h, "%s veritabaninda yazan SQL: %s" % (db, stmt[:200]), db)
            h.send_json(200, {"database": db, "write": True, "output": "UPDATE 3\n"})
        elif not stmt.lower().startswith(("select", "with", "show", "explain")):
            h.error(400, "sql_error", "ERROR:  cannot execute %s in a read-only transaction" % stmt.split()[0].upper())
        else:
            h.send_json(200, {"database": db, "columns": ["id", "email", "created_at"],
                              "rows": [["1", "ada@example.com", "2026-11-01"], ["2", "linus@example.com", "2026-11-02"]],
                              "row_count": 2, "truncated": False})
    elif what == "local-run":
        with state_lock:
            run = local_runs.get(pid)
            busy = run is not None and run["status"] in ("running", "building")
            port = int(body.get("port") or 18000 + pid)
            if not busy:
                local_runs[pid] = {"status": "building", "port": port, "started_at": now(), "error": ""}
        if busy:
            h.error(409, "conflict", "Bu proje zaten lokalde calisiyor")
            return True
        threading.Thread(target=finish_local_run, args=(pid,), daemon=True).start()
        h.send_json(200, {"success": True, "message": "Local run baslatildi", "container_name": "local-" + name, "port": port,
                          "db_host": "10.0.0.5", "db_source": "server", "local_url": "http://localhost:%d" % port,
                          "status_url": "%s/projects/%d/local-status" % (BASE, pid)})
    elif what == "local-stop":
        with state_lock:
            if pid in local_runs:
                local_runs[pid]["status"] = "stopped"
        h.send_json(200, {"success": True, "message": "Container durduruldu"})
    elif what == "refresh":
        h.send_json(200, dict(project, git_branch=project.get("branch") or "main"))
    elif what == "git-pull":
        h.send_json(200, {"success": True, "log": "Already up to date."})
    elif what in ("git-push", "switch-branch", "diagnose/fix"):
        if what == "switch-branch" and not body.get("branch"):
            h.error(400, "bad_request", "Branch name required")
            return True
        summaries = {"git-push": "git commit + push (uzak repoya gonderilir)", "switch-branch": "projenin branch'i degisecek",
                     "diagnose/fix": "otomatik duzeltme sunucuda degisiklik yapar"}
        if body.get("confirm") != name:
            return confirm_required(h, "%s: %s" % (name, summaries[what]), name)
        if what == "git-push":
            h.send_json(200, {"success": True, "log": "[main 1a2b3c4] auto commit\nTo origin: main -> main"})
        elif what == "switch-branch":
            h.send_json(200, {"success": True, "message": "Branch switched to " + body["branch"], "project": project})
        else:
            h.send_json(200, {"success": True, "message": "Duzeltildi: %s" % body.get("action")})
    elif what == "build":
        h.send_json(200, {"success": True, "output": "Step 1/7 : FROM golang:1.23\nStep 7/7 : CMD [\"/app\"]\nSuccessfully built 4f2c",
                          "binary": "", "image": "%s:latest" % name})
    elif what == "pull-deploy":
        servers = {s["id"]: s["name"] for s in fixture("servers.json")}
        if body.get("server_id") not in servers:
            h.error(404, "not_found", "Server not found")
            return True
        with state_lock:
            dep_id = max(deployments) + 1
            deployments[dep_id] = {"id": dep_id, "project_id": pid, "project_name": name, "server_id": body["server_id"],
                                   "server_name": servers[body["server_id"]], "status": "pending", "step": "git_pull", "error": None,
                                   "branch": project.get("branch"), "commit": None, "started_at": now(), "finished_at": None}
            deploy_lines[dep_id] = []
            deploy_done[dep_id] = False
        threading.Thread(target=play_deploy, args=(dep_id, name, servers[body["server_id"]]), daemon=True).start()
        h.send_json(200, {"success": True, "deployment_id": dep_id, "message": "Pull & Deploy started"})
    else:  # diagnose
        h.send_json(200, {"success": True, "project": name, "container_name": name.lower(), "server": "prod-eu-1", "checks": [
            {"name": "container", "label": "Container", "status": "ok", "message": "running", "fix_available": False},
            {"name": "network", "label": "Traefik network", "status": "error", "message": "not on traefik-net", "fix_available": True,
             "fix_action": "fix_network", "fix_detail": "Container aga eklenecek"},
        ]})
    return True


def v12_post(h, p, body):
    """POST routes; True when handled."""
    m = re.fullmatch(r"/projects/(\d+)/(env/rescan|sql|local-run|local-stop|refresh|git-pull|git-push|switch-branch|build|pull-deploy"
                     r"|diagnose|diagnose/fix)", p)
    if m:
        return v12_project_post(h, int(m.group(1)), m.group(2), body)
    m = re.fullmatch(r"/deployments/(\d+)/cancel", p)
    if m:
        with state_lock:
            d = deployments.get(int(m.group(1)))
        if not d:
            h.error(404, "not_found", "Deploy bulunamadi")
            return True
        if body.get("confirm") != d["project_name"]:
            return confirm_required(h, "%s deploy #%d iptal edilecek" % (d["project_name"], d["id"]), d["project_name"])
        if d["status"] in ("success", "failed"):
            h.error(400, "bad_request", "Deploy zaten tamamlanmis")
            return True
        with state_lock:
            d.update(status="failed", finished_at=now())
            deploy_done[d["id"]] = True
        h.send_json(200, {"success": True, "message": "Deploy iptal edildi"})
        return True
    m = re.fullmatch(r"/domains/(\d+)/(apply|deploy-nginx|purge-cache)", p)
    if m:
        domain = next((d for d in MOCK_DOMAINS if d["id"] == int(m.group(1))), None)
        if not domain:
            h.error(404, "not_found", "Domain bulunamadi")
        elif m.group(2) == "deploy-nginx" and domain["type"] != "static":
            h.error(400, "bad_request", "Domain is not a static site")
        elif m.group(2) == "apply":
            h.send_json(200, {"success": True})
        elif m.group(2) == "deploy-nginx":
            h.send_json(200, {"success": True, "message": "Nginx container deployed: static-" + domain["fqdn"].replace(".", "-")})
        else:
            h.send_json(200, {"success": True, "message": "Cache temizlendi: " + domain["fqdn"]})
        return True
    if p in ("/cloudflare/purge-zone", "/cloudflare/ssl-full"):
        base = body.get("base_domain")
        if not base:
            h.error(400, "bad_request", "base_domain gerekli")
        elif p.endswith("zone"):
            h.send_json(200, {"success": True, "message": "Tum cache temizlendi: %s" % base})
        else:
            h.send_json(200, {"success": True, "message": "SSL modu 'Full' olarak ayarlandi: %s" % base})
        return True
    m = re.fullmatch(r"/servers/(\d+)/env", p)
    if m:
        sid = int(m.group(1))
        if not body.get("key") or "value" not in body:
            h.error(400, "bad_request", "Key ve value gerekli")
            return True
        with state_lock:
            env = [(k, v) for k, v in server_env.get(sid, []) if k != body["key"]]
            server_env[sid] = env + [(body["key"], body["value"])]
        h.send_json(201, {"success": True, "id": len(server_env[sid])})
        return True
    m = re.fullmatch(r"/servers/(\d+)/pg/users", p)
    if m:
        sid = int(m.group(1))
        if not body.get("project_id"):
            h.error(400, "bad_request", "project_id gerekli: sifre projenin env'ine yazilir, agent'a donmez")
        elif not body.get("username"):
            h.error(400, "bad_request", "Kullanici adi gerekli")
        else:
            with state_lock:
                pg_users.setdefault(sid, []).append({"name": body["username"], "is_superuser": False, "databases": []})
            h.send_json(200, {"success": True, "message": "Kullanici olusturuldu", "username": body["username"]})
        return True
    m = re.fullmatch(r"/servers/(\d+)/pg/users/([A-Za-z0-9_]+)/grant", p)
    if m:
        if not body.get("database"):
            h.error(400, "bad_request", "Veritabani adi gerekli")
        else:
            h.send_json(200, {"success": True, "message": "Erisim yetkisi kaldirildi" if body.get("revoke") else "Erisim yetkisi verildi"})
        return True
    m = re.fullmatch(r"/servers/(\d+)/pg/databases/([A-Za-z0-9_]+)/(clone|clone-for-local)", p)
    if m:
        sid, source, kind = int(m.group(1)), m.group(2), m.group(3)
        if kind == "clone-for-local" and not body.get("project_id"):
            h.error(400, "bad_request", "project_id gerekli")
            return True
        target = body.get("target_name") or (source + "_dev" if kind == "clone-for-local" else "")
        if not target:
            h.error(400, "bad_request", "Yeni veritabani adi gerekli")
            return True
        job_id = secrets.token_hex(8)
        with state_lock:
            clone_jobs[job_id] = {"server_id": sid, "source": source, "target": target, "started": time.time()}
            if kind == "clone-for-local":
                local_env.setdefault(int(body["project_id"]), {})["DB_NAME"] = target
        res = {"success": True, "job_id": job_id, "source": source, "target": target, "message": "Klonlama baslatildi"}
        if kind == "clone-for-local":
            res["local_env"] = {"DB_NAME": target}
        h.send_json(202, res)
        return True
    return False


def v12_put(h, p, body):
    m = re.fullmatch(r"/projects/(\d+)/local-env", p)
    if m:
        vars_ = body.get("vars") or {}
        if not vars_:
            h.error(400, "bad_request", 'vars gerekli: {"vars":{"KEY":"value"}}')
            return True
        with state_lock:
            local_env.setdefault(int(m.group(1)), {}).update(vars_)
        h.send_json(200, {"written": sorted(vars_)})
        return True
    m = re.fullmatch(r"/domains/(\d+)", p)
    if m:
        domain = next((d for d in MOCK_DOMAINS if d["id"] == int(m.group(1))), None)
        if not domain:
            h.error(404, "not_found", "Domain bulunamadi")
            return True
        fqdn = domain["fqdn"]
        # Another server means another A record: the DNS-overwrite confirmation.
        if body.get("server_id") != domain["server_id"] and body.get("confirm") != fqdn:
            return confirm_required(h, "%s DNS kaydi degisecek: 203.0.113.10 → 203.0.113.20" % fqdn, fqdn)
        with state_lock:
            domain.update({k: v for k, v in body.items() if k != "confirm"})
        h.send_json(200, domain)
        return True
    return False


def v12_delete(h, p, body):
    # One project env row; confirm = its key (ServerPlan 427bfe6, agentDeleteProjectEnv).
    m = re.fullmatch(r"/projects/(\d+)/env/(\d+)", p)
    if m:
        pid, env_id = int(m.group(1)), int(m.group(2))
        rows = project_env_rows(pid) if project_by_id(pid) else []
        row = next((r for r in rows if r["id"] == env_id), None)
        if not row:
            h.error(404, "not_found", "Env kaydi bulunamadi")
            return True
        dupes = sum(1 for r in rows if r["key"] == row["key"] and r["id"] != env_id)
        summary = "env %s (#%d) silinecek" % (row["key"], env_id)
        if dupes:
            summary += "; ayni anahtarin %d kopyasi daha kalacak" % dupes
        else:
            summary += "; bu anahtarin baska kopyasi YOK, deploy'da tamamen kalkar"
        if body.get("confirm") != row["key"]:
            return confirm_required(h, summary, row["key"])
        with state_lock:
            env_deleted.setdefault(pid, set()).add(env_id)
        h.send_json(200, {"deleted": env_id, "key": row["key"], "remaining_copies": dupes})
        return True
    m = re.fullmatch(r"/projects/(\d+)/local-env/([^/]+)", p)
    if m:
        pid, key = int(m.group(1)), unquote(m.group(2))
        with state_lock:
            found = local_env.get(pid, {}).pop(key, None) is not None
        if not found:
            h.error(404, "not_found", "Bu anahtar icin lokal override yok")
        else:
            h.send_json(200, {"deleted": key})
        return True
    return False


# --- Agent API v1.3: domain check and purchase (ServerPlan 1f919c9, agent_domain_buy.go) ---------
# Never a registrar: names pick the answer. taken.com and *.taken are registered; premium.* is a
# premium domain; pricey.* costs over the cap; costly.* is more than the balance for 2 years;
# anything else is available at 9.98 USD (13.98 renewal). Purchases are refused (412
# purchase_disabled) unless --purchase enabled.

PRICE_CAP = 25.0
purchased = {}        # domain -> purchase id
# v1.4: the Namecheap balance (--balance, --low-threshold) and its edge state, like the panel's cache.
registrar = {"available": 30.0, "account": 30.0, "threshold": 0.0, "low": False, "checked": None}
DOMAIN_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+")


def domain_quote(name):
    available = not (name == "taken.com" or name.endswith(".taken") or name in purchased)
    premium = name.startswith("premium.")
    price, renewal = (9.98, 13.98)
    if premium:
        price, renewal = (1450.0, 1450.0)
    elif name.startswith("pricey."):
        price, renewal = (40.0, 42.0)
    elif name.startswith("costly."):
        price, renewal = (18.0, 20.0)
    return {"domain": name, "available": available, "premium": premium, "price": price, "renewal_price": renewal, "currency": "USD"}


def set_balance(available, account=None):
    """The panel's registrarBalance(): records the balance and emits on a threshold crossing."""
    with state_lock:
        registrar["available"] = float(available)
        registrar["account"] = float(account if account is not None else max(registrar["account"], available))
        registrar["checked"] = now()
        threshold = registrar["threshold"]
        was_low = registrar["low"]
        is_low = threshold > 0 and registrar["available"] < threshold
        registrar["low"] = is_low
    data = {"available_balance": registrar["available"], "currency": "USD", "low_threshold": threshold}
    if is_low and not was_low:
        emit("registrar.low_balance", data)
    elif was_low and not is_low:
        emit("registrar.balance_ok", data)


def registrar_balance(h, query):
    if args.namecheap == "unconfigured":
        return h.error(412, "not_configured", "Namecheap ayarlari yapilmamis")
    if (query.get("refresh") or [""])[0] == "1" or registrar["checked"] is None:
        set_balance(registrar["available"], registrar["account"])
    threshold = registrar["threshold"]
    h.send_json(200, {"available_balance": registrar["available"], "account_balance": registrar["account"], "currency": "USD",
                      "low_threshold": threshold if threshold > 0 else None,
                      "low": threshold > 0 and registrar["available"] < threshold, "checked_at": registrar["checked"]})


def domain_check(h, query):
    name = (query.get("name") or [""])[0].strip().lower()
    if not DOMAIN_RE.fullmatch(name):
        return h.error(400, "bad_request", "gecersiz domain: %r" % name)
    if args.namecheap == "unconfigured":
        return h.error(412, "not_configured", "Namecheap ayarlari yapilmamis")
    a = domain_quote(name)
    reason = ""
    if not a["available"]:
        reason = "domain musait degil"
    elif a["premium"]:
        reason = "premium domain: agent satin alamaz"
    elif a["price"] > PRICE_CAP:
        reason = "fiyat %.2f, sinir %.2f" % (a["price"], PRICE_CAP)
    elif args.purchase != "enabled":
        reason = "agent domain satin alma panelde kapali"
    res = dict(a, price_cap=PRICE_CAP, purchase_allowed=reason == "", reason=reason)
    if args.v14:
        # Like the panel: the balance, and "bakiye yetersiz" when it can't cover the first year.
        res.update(balance=registrar["available"], balance_currency="USD")
        if reason == "" and registrar["available"] < a["price"]:
            res.update(purchase_allowed=False, reason="bakiye yetersiz: %.2f" % registrar["available"])
    h.send_json(200, res)


def domain_purchase(h, body):
    name = str(body.get("domain") or "").strip().lower()
    if not DOMAIN_RE.fullmatch(name):
        return h.error(400, "bad_request", "gecersiz domain: %r" % name)
    years = body.get("years") or 1
    if years not in (1, 2):
        return h.error(400, "bad_request", "years 1 veya 2 olabilir")
    ref = str(body.get("approval_ref") or "").strip()
    if not ref:
        return h.error(400, "bad_request", "approval_ref gerekli (sahibinin onay karari)")
    if args.purchase != "enabled":
        return h.error(412, "purchase_disabled", "Agent domain satin alma panelde kapali (Entegrasyonlar > Namecheap)")
    if name in purchased:
        return h.error(409, "conflict", "Bu domain daha once satin alindi")
    a = domain_quote(name)
    if not a["available"]:
        return h.error(409, "conflict", "Domain musait degil")
    if a["premium"]:
        return h.error(403, "premium_domain", "Premium domain (%.2f USD): agent satin alamaz, sahibi elle almali" % a["price"])
    if a["price"] > PRICE_CAP:
        return h.error(403, "price_cap", "Fiyat %.2f USD/yil, sinir %.2f: sahibi siniri panelden artirmali" % (a["price"], PRICE_CAP))
    total = a["price"] + a["renewal_price"] * (years - 1)
    if registrar["available"] < total:
        return h.error(402, "insufficient_balance", "Namecheap bakiyesi yetersiz: %.2f, gereken %.2f USD" % (registrar["available"], total))
    summary = "%s %d yil icin satin alinacak: ~%.2f USD (yenileme %.2f/yil), onay %s" % (name, years, total, a["renewal_price"], ref)
    if body.get("confirm") != name:
        return confirm_required(h, summary, name)
    with state_lock:
        purchased[name] = len(purchased) + 1
        pid = purchased[name]
    setup_dns = body.get("setup_dns", True)
    ns = ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"] if setup_dns else []
    zone = {"name": name, "status": "pending", "nameservers": ns} if setup_dns else None
    set_balance(registrar["available"] - total, registrar["account"] - total)  # refresh + low-balance check
    emit("domain.purchased", {"domain": name, "charged_amount": total, "currency": "USD", "approval_ref": ref})
    h.send_json(201, {"domain": name, "years": years, "charged_amount": total, "currency": "USD", "order_id": "MOCK-%d" % (9000 + pid),
                      "purchase_id": pid, "nameservers": ns, "cloudflare_zone": zone, "whois_privacy": True})


# --- Containers: ServerPlan agent API 1.6 (`--v16`) and the still-proposed rest (`--containers`) --
# 1.6 (ServerPlan internal/web/handlers/agent_containers.go, agent_api.go): container_details,
# container_inspect, container_stats, server_stats, log_query, container_exec. `--containers` adds
# what ClaudeDeck still proposes (docs/serverplan-containers.md §5.7-5.10): recreate / pull /
# remove, docker disk and prune.

V16_FEATURES = ["container_details", "container_inspect", "container_stats", "server_stats", "log_query"]
PROPOSED_FEATURES = ["container_recreate", "image_update", "container_remove", "docker_prune"]
removed_containers = set()   # (server id, name) removed with DELETE
net_counters = {}            # server id or (server id, name) -> [rx, tx]
PROTECTED = ("traefik", "postgres", "redis")
LOG_TIME_RE = re.compile(r"^[0-9TZ:.+-]{1,40}$|^[0-9]+[smh]$")
NAME_RE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}")


def known_server(sid):
    return any(s["id"] == sid for s in fixture("servers.json"))


def parse_health(status):
    """monitor.ParseHealth: the health part of docker's status column."""
    s = (status or "").lower()
    if "(unhealthy)" in s:
        return "unhealthy"
    if "(healthy)" in s:
        return "healthy"
    if "(health: starting)" in s or "(starting)" in s:
        return "starting"
    return "none"


def container_rows(sid):
    name = "containers-%d.json" % sid
    rows = fixture(name) if os.path.exists(os.path.join(FIXTURES, name)) else []
    rows = [r for r in rows if (sid, r["name"]) not in removed_containers]
    if not args.v16:
        # What a 1.4/1.5 panel sends.
        return [{k: r[k] for k in ("name", "image", "state", "status", "ports") if k in r} for r in rows]
    projects = {p["display_name"].lower(): p for p in fixture("projects.json")}
    for r in rows:
        r.setdefault("id", hashlib.sha1(("%d/%s" % (sid, r["name"])).encode()).hexdigest()[:12])
        r.setdefault("created", "2026-11-18 07:58:10 +0000 UTC")
        r.setdefault("health", parse_health(r.get("status")))
        project = projects.get(r["name"].lower())
        # Like the panel: always present, null without a match.
        r.setdefault("project_id", project["id"] if project else None)
        r.setdefault("project_name", project["display_name"] if project else None)
        r.setdefault("domains", [d["fqdn"] for d in MOCK_DOMAINS if d["server_id"] == sid and d.get("target") == r["name"]])
    return rows


def counters(key, rx_rate, tx_rate):
    with state_lock:
        c = net_counters.setdefault(key, [10_000_000, 2_000_000])
        c[0] += int(rx_rate * (0.5 + random_unit()))
        c[1] += int(tx_rate * (0.5 + random_unit()))
        return list(c)


def random_unit():
    return int.from_bytes(secrets.token_bytes(2), "big") / 65535.0


def container_stats(sid, row):
    rx, tx = counters((sid, row["name"]), 40_000, 15_000)
    limit = 2 * 1024 ** 3
    used = int((120 + 80 * random_unit()) * 1024 ** 2)
    return {"name": row["name"], "cpu_percent": round(0.5 + 6 * random_unit(), 2), "mem_used_bytes": used, "mem_limit_bytes": limit,
            "mem_percent": round(used / limit * 100, 2), "net_rx_bytes": rx, "net_tx_bytes": tx, "block_read_bytes": 4096,
            "block_write_bytes": 1_048_576, "pids": 7, "checked_at": now()}


def inspect_ports(ps_ports):
    """docker ps's ports column as inspect's NetworkSettings.Ports: `public` null when unmapped."""
    out, seen = [], set()
    for item in [x.strip() for x in (ps_ports or "").split(",") if x.strip()]:
        host, arrow, inner = item.rpartition("->")
        port, _, proto = (inner if arrow else item).partition("/")
        public, ip = None, ""
        if arrow:
            ip, _, hp = host.rpartition(":")
            public = int(hp) if hp.isdigit() else None
        key = (port, public, proto)
        if key in seen:
            continue
        seen.add(key)
        out.append({"private": int(port) if port.isdigit() else 0, "public": public, "type": proto or "tcp", "ip": ip})
    return out


def inspect_body(sid, row):
    """monitor.ParseInspect plus the project link (agentContainerInspect)."""
    state = row.get("state", "")
    health = row.get("health") or parse_health(row.get("status"))
    m = re.match(r"Exited \((-?\d+)\)", row.get("status", ""))
    exit_code = int(m.group(1)) if m else 0
    if state == "running":
        status = "running (%s)" % health if health != "none" else "running"
    elif state == "exited":
        status = "exited (%d)" % exit_code
    else:
        status = state
    exited = state != "running"
    return {"name": row["name"], "id": row["id"][:12], "image": row.get("image", ""), "image_id": "sha256:" + row["id"] * 5,
            "state": state, "status": status, "health": health, "exit_code": exit_code,
            "started_at": "2026-11-18T07:58:11.123456789Z", "finished_at": "2026-11-20T10:31:02.5Z" if exited else None,
            "created_at": "2026-11-18T07:58:10.987654321Z", "restart_count": 3 if exited else 0,
            "restart_policy": "unless-stopped", "oom_killed": False, "ports": inspect_ports(row.get("ports")),
            "networks": ["traefik-network"], "mounts": [{"source": "/opt/volumes/" + row["name"], "destination": "/data", "rw": True}],
            "env_keys": ["PORT", "DATABASE_URL", "DATA_PATH"], "labels": {},
            "project_id": row.get("project_id"), "project_name": row.get("project_name"), "domains": row.get("domains", [])}


def log_entries(name, count=40):
    """(time, line) pairs; docker prints the time only with --timestamps."""
    out = []
    for i in range(count):
        t = "2026-11-18T09:%02d:00.000000000Z" % (i % 60)
        if i % 13 == 7:
            out.append((t, "%s | ERROR db query failed: connection refused" % name))
        elif i % 11 == 5:
            out.append((t, "%s | WARN slow request 1.2s" % name))
        else:
            out.append((t, "%s | request %d ok" % (name, i)))
    return out


def log_query_problem(query, stream):
    """parseAgentLogQuery: the 400 message, or None."""
    since, until, grep = (query.get(k, [""])[0] for k in ("since", "until", "grep"))
    if since and not LOG_TIME_RE.match(since):
        return "Gecersiz since degeri (RFC 3339 veya 10m, 2h gibi)"
    if stream and (until or grep):
        return "Canli akista until ve grep desteklenmez"
    if until and not LOG_TIME_RE.match(until):
        return "Gecersiz until degeri (RFC 3339 veya 10m, 2h gibi)"
    if len(grep.encode()) > 200:
        return "grep en fazla 200 karakter olabilir"
    if any(c in grep for c in "\n\r\x00"):
        return "grep tek satir olmali"
    return None


def in_window(t, since, until):
    """since/until as RFC 3339 prefixes compared as text (the mock's lines are all on one day)."""
    if since and LOG_TIME_RE.match(since) and not re.fullmatch(r"[0-9]+[smh]", since) and t < since:
        return False
    if until and not re.fullmatch(r"[0-9]+[smh]", until) and t > until:
        return False
    return True


def container_logs(h, sid, name, query):
    if not known_server(sid):
        return h.error(404, "not_found", "Sunucu bulunamadi")
    tail = max(1, min(5000, int((query.get("tail") or ["200"])[0] or 200)))
    if not args.v16:
        text = "\n".join("%s %s" % (t, line) for t, line in log_entries(name)[-tail:])
        return send_text(h, text)
    problem = log_query_problem(query, False)
    if problem:
        return h.error(400, "bad_request", problem)
    since, until, grep = (query.get(k, [""])[0] for k in ("since", "until", "grep"))
    stamps = (query.get("timestamps") or [""])[0] in ("1", "true")
    if not any(r["name"] == name for r in container_rows(sid)):
        # docker logs fails; with grep the pipe swallows the error (an empty 200).
        if grep:
            return send_text(h, "")
        return h.error(502, "server_unreachable", "Error response from daemon: No such container: " + name)
    lines = [(t, l) for t, l in log_entries(name) if in_window(t, since, until)]
    if grep:
        lines = [(t, l) for t, l in lines if grep.lower() in l.lower()]
    lines = lines[-tail:]
    send_text(h, "\n".join(("%s %s" % (t, l)) if stamps else l for t, l in lines))


def containers_get(h, p, query):
    """GETs of the container routes; False when it isn't one."""
    m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/logs", p)
    if m:
        container_logs(h, int(m.group(1)), unquote(m.group(2)), query)
        return True
    if not args.v16:
        return False
    m = re.fullmatch(r"/servers/(\d+)/containers(?:/stats|/[^/]+(?:/stats)?)?", p)
    if m and not known_server(int(m.group(1))):
        h.error(404, "not_found", "Sunucu bulunamadi")
        return True
    m = re.fullmatch(r"/servers/(\d+)/containers", p)
    if m:
        h.send_json(200, container_rows(int(m.group(1))))
        return True
    m = re.fullmatch(r"/servers/(\d+)/health", p)
    if m and int(m.group(1)) != 3:
        sid = int(m.group(1))
        rx, tx = counters(sid, 300_000, 120_000)
        cpu = round(3 + 20 * random_unit(), 1)
        mem_total = 4 * 1024 ** 3
        mem_used = int(mem_total * (0.35 + 0.1 * random_unit()))
        body = {"reachable": True, "docker_ok": True, "cpu": "%s%%" % cpu, "memory": "%.1fGi/4.0Gi" % (mem_used / 1024 ** 3),
                "disk": "9G/40G (22%)", "uptime": "up 3 days", "load_avg": "0.42 0.37 0.30", "checked_at": now(),
                "cpu_percent": cpu, "cores": 4, "mem_used_bytes": mem_used, "mem_total_bytes": mem_total,
                "disk_used_bytes": 9 * 1024 ** 3, "disk_total_bytes": 40 * 1024 ** 3, "load1": 0.42, "load5": 0.37,
                "load15": 0.30, "net_rx_bytes": rx, "net_tx_bytes": tx, "uptime_seconds": 259200}
        if sid == 2:
            # A field the panel couldn't read is null on its own.
            body.update(net_rx_bytes=None, net_tx_bytes=None)
        h.send_json(200, body)
        return True
    m = re.fullmatch(r"/servers/(\d+)/containers/stats", p)
    if m:
        sid = int(m.group(1))
        h.send_json(200, [container_stats(sid, r) for r in container_rows(sid) if r.get("state") == "running"])
        return True
    m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/stats", p)
    if m:
        sid, name = int(m.group(1)), unquote(m.group(2))
        row = next((r for r in container_rows(sid) if r["name"] == name), None)
        if not NAME_RE.fullmatch(name):
            h.error(400, "bad_request", "Gecersiz container adi")
        elif not row:
            h.error(404, "not_found", "Container bulunamadi")
        else:
            # A list, like the all-containers route (docker stats NAME).
            h.send_json(200, [container_stats(sid, row)])
        return True
    m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)", p)
    if m:
        sid, name = int(m.group(1)), unquote(m.group(2))
        row = next((r for r in container_rows(sid) if r["name"] == name), None)
        if not NAME_RE.fullmatch(name):
            h.error(400, "bad_request", "Gecersiz container adi")
        elif not row:
            h.error(404, "not_found", "Container bulunamadi")
        else:
            h.send_json(200, inspect_body(sid, row))
        return True
    if not args.containers:
        return False
    m = re.fullmatch(r"/servers/(\d+)/docker/disk", p)
    if m:
        h.send_json(200, {"images": {"count": 14, "active": 5, "size_bytes": 6_400_000_000, "reclaimable_bytes": 3_900_000_000},
                          "containers": {"count": 6, "active": 4, "size_bytes": 120_000_000, "reclaimable_bytes": 40_000_000},
                          "volumes": {"count": 4, "active": 3, "size_bytes": 2_100_000_000, "reclaimable_bytes": 300_000_000},
                          "build_cache": {"count": 52, "active": 0, "size_bytes": 1_700_000_000, "reclaimable_bytes": 1_700_000_000}})
        return True
    return False


def server_name(sid):
    return next((s["name"] for s in fixture("servers.json") if s["id"] == sid), "server")


def containers_post(h, p, body):
    if not args.containers:
        return False
    m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/(recreate|pull)", p)
    if m:
        sid, name, op = int(m.group(1)), unquote(m.group(2)), m.group(3)
        if body.get("confirm") != name:
            what = "yeniden olusturulur (mevcut imaj, guncel env)" if op == "recreate" else "imaji cekilir, degistiyse yeniden olusturulur"
            confirm_required(h, "%s @ %s: container %s" % (name, server_name(sid), what), name)
        elif op == "pull":
            h.send_json(200, {"success": True, "updated": name != "postgres", "old_image_id": "sha256:aaa", "new_image_id": "sha256:bbb",
                              "output": "Status: Downloaded newer image for %s" % name})
        else:
            h.send_json(200, {"success": True, "id": secrets.token_hex(6)})
        return True
    m = re.fullmatch(r"/servers/(\d+)/docker/prune", p)
    if m:
        sid = int(m.group(1))
        name = server_name(sid)
        if body.get("confirm") != name:
            parts = []
            if body.get("images", "dangling") != "none":
                parts.append("imajlar (%s)" % body.get("images", "dangling"))
            if body.get("containers", True):
                parts.append("durmus containerlar")
            if body.get("build_cache", True):
                parts.append("build cache")
            if body.get("volumes"):
                parts.append("KULLANILMAYAN VOLUME'LAR VE VERILERI")
            confirm_required(h, "%s: %s silinecek (~5.6 GB geri kazanilabilir)" % (name, ", ".join(parts) or "hicbir sey"), name)
        else:
            h.send_json(200, {"success": True, "reclaimed_bytes": 5_640_000_000, "output": "Total reclaimed space: 5.64GB"})
        return True
    return False


def containers_delete(h, p, body):
    if not args.containers:
        return False
    m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)", p)
    if not m:
        return False
    sid, name = int(m.group(1)), unquote(m.group(2))
    if name in PROTECTED:
        h.error(400, "bad_request", "%s silinemez" % name)
    elif body.get("confirm") != name:
        confirm_required(h, "%s @ %s: container silinir (docker rm -f; volume'lar kalir)" % (name, server_name(sid)), name)
    else:
        with state_lock:
            removed_containers.add((sid, name))
        h.send_json(200, {"success": True})
    return True


# --- Rate limiting (ServerPlan 1.5, `--v15`) ------------------------------------------------------

rate_rules = {}   # base domain -> [rule]


def rate_base(host):
    return ".".join(host.lower().split(".")[-2:])


def ratelimit_get(h, query):
    host = (query.get("host") or [""])[0]
    if args.cloudflare == "unconfigured":
        return h.error(412, "not_configured", "Cloudflare token ayarli degil")
    if not host.endswith(("example.com", "example.org", "acme.example")):
        return h.error(404, "not_found", "Cloudflare zone bulunamadi: " + rate_base(host))
    h.send_json(200, {"zone_rules": rate_rules.get(rate_base(host), [])})


def ratelimit_post(h, p, body):
    host = (body.get("host") or "").lower()
    if args.cloudflare == "unconfigured":
        return h.error(412, "not_configured", "Cloudflare token ayarli degil")
    if p == "/ratelimit/clear":
        if body.get("confirm") != host:
            return confirm_required(h, "zone'daki rate-limit kurallari kaldirilacak (API korumasi kalkar)", host)
        rate_rules.pop(rate_base(host), None)
        return h.send_json(200, {"cleared": True})
    paths = body.get("paths") or ["/init"]
    if "." not in host or any(not re.fullmatch(r"/[A-Za-z0-9._~/-]*\*?", x) for x in paths):
        return h.error(400, "bad_request", "gecersiz host veya path")
    if not host.endswith(("example.com", "example.org", "acme.example")):
        return h.error(404, "not_found", "Cloudflare zone bulunamadi: " + rate_base(host))
    requests, period = body.get("requests") or 20, body.get("period") or 10
    conds = " or ".join('starts_with(http.request.uri.path, "%s")' % x[:-1] if x.endswith("*") else 'http.request.uri.path eq "%s"' % x
                        for x in paths)
    rule = {"description": "serverplan: %s %s" % (host, ",".join(paths)), "expression": '(http.host eq "%s" and (%s))' % (host, conds),
            "action": "block", "ratelimit": {"characteristics": ["ip.src", "cf.colo.id"], "period": period,
                                             "requests_per_period": requests, "mitigation_timeout": period}}
    existing = rate_rules.get(rate_base(host), [])
    if existing and body.get("confirm") != host:
        names = "; ".join("%s [%s]" % (r["description"], r["expression"]) for r in existing)
        return confirm_required(h, "zone'daki mevcut rate-limit kurali degisecek: %s → %s" % (names, rule["description"]), host)
    rate_rules[rate_base(host)] = [rule]
    h.send_json(200, {"rule": rule})


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
                me = fixture("v12-me.json" if args.v12 or args.v13 else "me.json")
                if args.v13:
                    me.update(server_version="1.3.0", scopes=me["scopes"] + ["domains_buy"],
                              features=me["features"] + ["env_delete", "domain_check", "domain_purchase"])
                if args.v14:
                    me.update(server_version="1.4", features=me["features"] + ["registrar_balance"])
                if args.v15:
                    me.update(server_version="1.5", features=me["features"] + ["ratelimit"],
                              scopes=sorted(set(me["scopes"]) | {"dns"}))
                if args.v16:
                    features = me["features"] + V16_FEATURES
                    # Like the panel: only with the terminal scope (servers.ssh + containers.control).
                    if "terminal" in me["features"]:
                        features.append("container_exec")
                    me.update(server_version="1.6", features=features)
                if args.containers:
                    me.update(features=me["features"] + PROPOSED_FEATURES)
                return self.send_json(200, me)
            if p == "/ratelimit" and args.v15:
                return ratelimit_get(self, query)
            if containers_get(self, p, query):
                return
            if p == "/domains/check":
                return domain_check(self, query)
            if p == "/registrar/balance" and args.v14:
                return registrar_balance(self, query)
            if v12_get(self, p, query):
                return
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
            m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/logs/stream", p)
            if m:
                if not known_server(int(m.group(1))):
                    return self.error(404, "not_found", "Sunucu bulunamadi")
                if args.v16:
                    problem = log_query_problem(query, True)
                    if problem:
                        return self.error(400, "bad_request", problem)
                return self.log_stream(unquote(m.group(2)), (query.get("timestamps") or [""])[0] in ("1", "true"))
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

    def log_stream(self, container, stamps=False):
        def stamp(line):
            return ("%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S.000000000Z", time.gmtime()), line)) if stamps else line
        self.sse_start()
        if container == "payments-api":  # exited container: the tail, then docker logs ends
            for line in deploy_lines.get(207, [])[-3:]:
                self.sse("log", {"line": stamp(line), "stream": "stderr"})
            self.sse("end", {"reason": "log stream ended"})
            return
        i = 0
        while True:
            if i % 7 == 6:
                self.sse("log", {"line": stamp("%s | ERROR upstream timeout after 30s (GET /api/orders)" % container), "stream": "stderr"})
            else:
                self.sse("log", {"line": stamp("%s | GET /health 200 %dms" % (container, 2 + i % 5)), "stream": "stdout"})
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
        if url.path == "/_demo/balance":
            # Sets the Namecheap balance: crossing the --low-threshold emits registrar.low_balance / balance_ok.
            value = (parse_qs(url.query).get("value") or [""])[0]
            try:
                set_balance(float(value))
            except ValueError:
                return self.error(400, "bad_request", "value=N (USD)")
            return self.send_json(200, {"ok": True, "available_balance": registrar["available"], "low": registrar["low"]})
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
            if command not in ("shell", "claude", "exec") or (command == "exec" and not args.v16):
                return self.error(400, "bad_request", "command sadece shell, claude veya exec olabilir")
            if command == "exec":
                # agentWSTicket (1.6): name check, then the server (404), then docker inspect
                # (404 unknown container, 400 not running). No 428.
                name = body.get("container") or ""
                if not NAME_RE.fullmatch(name):
                    return self.error(400, "bad_request", "exec icin gecerli bir container adi gerekli")
                if not known_server(sid):
                    return self.error(404, "not_found", "Sunucu bulunamadi")
                row = next((r for r in container_rows(sid) if r["name"] == name), None)
                if not row:
                    return self.error(404, "not_found", "Container bulunamadi")
                if row.get("state") != "running":
                    return self.error(400, "bad_request", "Container calismiyor")
                command = "exec:" + name
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
        if p in ("/ratelimit", "/ratelimit/clear") and args.v15:
            return ratelimit_post(self, p, body)
        if containers_post(self, p, body):
            return
        m = re.fullmatch(r"/servers/(\d+)/containers/([^/]+)/(start|stop|restart)", p)
        if m:
            name, verb = unquote(m.group(2)), m.group(3)
            if body.get("confirm") != name:
                words = {"start": "başlatılır", "stop": "durdurulur", "restart": "yeniden başlatılır"}
                return self.error(428, "confirm_required", "Bu işlem onay gerektirir",
                                  summary="%s konteyneri %s." % (name, words[verb]), confirm=name)
            return self.send_json(200, {"ok": True})
        if p == "/domains/purchase":
            return domain_purchase(self, body)
        if v12_post(self, p, body):
            return
        self.error(404, "not_found", "Bulunamadı")

    # PUT, DELETE (v1.2)
    def agent_path(self):
        url = urlparse(self.path)
        if not url.path.startswith(BASE):
            self.error(404, "not_found", "Bulunamadı")
            return None
        if not self.authed():
            return None
        return url.path[len(BASE):]

    def do_PUT(self):
        p = self.agent_path()
        if p is not None and not v12_put(self, p, self.body()):
            self.error(404, "not_found", "Bulunamadı")

    def do_DELETE(self):
        p = self.agent_path()
        if p is None:
            return
        body = self.body()
        if not containers_delete(self, p, body) and not v12_delete(self, p, body):
            self.error(404, "not_found", "Bulunamadı")


def main():
    global args
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=5099)
    parser.add_argument("--token", default="spk_1_demo")
    parser.add_argument("--root", default="/tmp/ClaudeDeckDemo")
    parser.add_argument("--claude", default=None, help="what a 'claude' terminal runs (the demo stand-in)")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--v12", action="store_true", help="/me says 1.2.0 with the v1.1/v1.2 scopes (sql, sql_write, local...)")
    parser.add_argument("--v13", action="store_true", help="/me says 1.3.0: the v1.2 scopes plus domains_buy, features domain_check/domain_purchase")
    parser.add_argument("--purchase", choices=("disabled", "enabled"), default="disabled",
                        help="agent domain purchases in the panel: disabled (412 purchase_disabled, the panel's default) or enabled (mock 201s)")
    parser.add_argument("--v14", action="store_true", help="/me says 1.4 (implies --v13): GET /registrar/balance, the balance in domain check, registrar.* events")
    parser.add_argument("--balance", type=float, default=30.0, help="the mock Namecheap balance in USD (default 30)")
    parser.add_argument("--low-threshold", type=float, default=0.0, help="the panel's low-balance threshold in USD (0: none, the panel's default)")
    parser.add_argument("--namecheap", choices=("configured", "unconfigured"), default="configured",
                        help="unconfigured: /registrar/balance and /domains/check answer 412 not_configured")
    parser.add_argument("--v15", action="store_true", help="/me says 1.5 (implies --v14): GET/POST /ratelimit, POST /ratelimit/clear")
    parser.add_argument("--cloudflare", choices=("configured", "unconfigured"), default="configured",
                        help="unconfigured: /ratelimit answers 412 not_configured")
    parser.add_argument("--v16", action="store_true",
                        help="/me says 1.6 (implies --v15): container details / inspect / stats, numbers on health, logs "
                             "since/until/grep/timestamps, container_exec terminals (ServerPlan's real 1.6 shapes)")
    parser.add_argument("--containers", action="store_true",
                        help="--v16 plus what ClaudeDeck still proposes (docs/serverplan-containers.md §5.7-5.10): "
                             "recreate/pull/remove, docker disk/prune")
    args = parser.parse_args()
    if args.containers:
        args.v16 = True
    if args.v16:
        args.v15 = True
    if args.v15:
        args.v14 = True
    if args.v14:
        args.v13 = True
    registrar.update(available=args.balance, account=args.balance, threshold=max(0.0, args.low_threshold))
    if args.port == 5050:
        raise SystemExit("refusing :5050 (the real panel's port)")
    load_state()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print("ServerPlan mock on http://127.0.0.1:%d (token %s)" % (args.port, args.token), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
