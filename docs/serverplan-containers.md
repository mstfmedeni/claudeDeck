# ServerPlan containers and servers: what exists, what ClaudeDeck uses, what's missing

Inventory of ServerPlan's container and server capabilities (ServerPlan repo
`~/Desktop/ServerPlan/servermanager`, agent API `server_version` **1.4**, checked 2026-11-20) and
how ClaudeDeck uses them. The proposed additions at the end are what ClaudeDeck is already
feature-gated on: it lights them up as soon as `/me` lists their feature.

## 1. The agent API today (`/api/v1/agent`, bearer token)

Routes in `internal/web/handlers/agent_api.go`, `agent_streams.go`, `agent_v11.go`, `agent_v12.go`.
Every call is rate limited (120/min per token) and audited; a scope only narrows the token
owner's permissions.

| Route | Scope · permission | What it gives |
|---|---|---|
| `GET /me` | any | `user`, `role`, `scopes`, `server_version` ("1.4"), `features` (below) |
| `GET /servers` | read · servers.view | `[{id,name,host,status,health:{reachable,checked_at}}]` (reachability cached, polled every 2 min once an agent is active) |
| `GET /servers/:id/health` | read · servers.view_details | live over SSH: `{reachable, docker_ok, cpu:"12.3%", memory:"1.2G/3.8G", disk:"9G/40G (22%)", uptime:"up 3 days", load_avg:"0.10 0.20 0.30", checked_at}` (strings from `top`/`free -h`/`df -h`, no network, no numbers) |
| `GET /servers/:id/capabilities[?refresh=1]` | read | `{claude, claude_path, checked_at}` (cached 10 min) |
| `GET /servers/:id/containers` | read · containers.view\|control | `[{name,image,state,status,ports}]` from `docker ps -a` (the panel also reads `id` and `created` but drops them; no health, no project, no domain) |
| `GET /servers/:id/containers/:name/logs?tail=N` | logs · containers.view\|projects.view | text/plain, `docker logs --tail N 2>&1` (1..5000; **no `since`, no `grep`, no timestamps**) |
| `GET /servers/:id/containers/:name/logs/stream?tail=N` | logs | SSE `event: log {"line","stream":"stdout"\|"stderr"}`, `event: end {"reason"}`, `: ping` every 25 s (`docker logs -f`) |
| `POST /servers/:id/containers/:name/(start\|stop\|restart)` | containers · containers.control | 428 `{error:"confirm_required",summary,confirm:<name>}` until `{"confirm":"<name>"}` |
| `GET /servers/:id/ports` | read · servers.view_details | `used_ports {port: domain}`, `port_projects`, `suggested_port`, `free_ports` |
| `POST /ws-ticket` `{server_id,cols,rows,command:"shell"\|"claude"}` | terminal · servers.ssh | single-use 60 s ticket; `GET /ws/terminal?ticket=` is a PTY over WebSocket (binary stdin/stdout, text `{"type":"resize"}`, `{"type":"exit","code"}`). **Server shell only, no `docker exec`** |
| `GET /events` (SSE, `Last-Event-ID`) | read | `deploy.*`, `server.unreachable` / `server.recovered`, `registrar.*` (**no container events**) |
| `GET /projects`, `/deployments`, `/deployments/:id[/stream]`, `POST /projects/:id/deploy` | read / deploy | projects (with `domain`, `last_deploy`), deploy log replay + live SSE |
| `GET /domains[?server_id=]` | read · domains.view | raw domain rows: `id, server_id, subdomain, base_domain, type (go_app\|static\|redirect), target, port, project_name, ssl_enabled, websocket_enabled, …` |
| `GET/POST /projects/:id/env`, `POST …/env/bulk`, `…/env/rescan`, `DELETE …/env/:envId` | read / projects_write · projects.manage_env | the project's deploy env (secret values never sent back; delete needs confirm = key) |
| `GET/POST /servers/:id/env` | read / projects_write · admin | server-level env |
| v1.2: `build`, `pull-deploy`, `git-*`, `diagnose[/fix]`, `deployments/:id/cancel`, `domains/:id` PUT/apply/nginx/purge, `pg/*`, `sql`, `local-*` | various | see docs/agents.md |
| v1.3/1.4: `domains/check`, `domains/purchase`, `registrar/balance` | read / domains_buy | domains |

`/me` features in 1.4: `deploy_stream, log_stream, events, ports, project_scan, project_settings,
env, env_rescan, dockerfile, auto_create_db, domains, dns_sync, cloudflare_zones,
namecheap_nameservers, static_sites, sql, local_run, local_env, clone_for_local, git, diagnose,
pg_admin, cloudflare_cache_ssl, server_env, env_delete, domain_check, domain_purchase,
registrar_balance`, plus `terminal, terminal_claude` with the terminal scope and `servers.ssh`.

How containers relate to projects and domains (the panel's own rule, `servers.go ListContainers`
and `deploy/deployer.go`): a `go_app` domain's container is `lower(target)` or
`lower(project_name)`; the project's container is `lower(target)` of its domain, else
`lower(display_name)`; a static site's container is `nginx-<sub>-<base with dashes>`
(`nginx-<base with dashes>` for the root).

## 2. The panel's own routes (session cookie, not reachable by agents)

| Route | Notes |
|---|---|
| `GET /api/servers/:id/containers` | grouped by base domain, with `id`, `created`, `subdomain`, `domain_type`, `last_deploy_at`, `last_sync_at` |
| `GET /api/servers/:id/stats` | the same five strings as agent `health` |
| `DELETE /api/servers/:id/containers/:name` (admin) | `docker rm -f` |
| `GET /api/servers/:id/containers/:name/logs?lines=` | same as the agent tail |
| `GET /ws/logs/:serverId/:container` | WebSocket log follow (`docker logs -f --tail 5000`) |
| `GET /ws/terminal/:serverId` (admin) | server shell over WebSocket (the agent terminal is the same thing) |

Present in the code but **not routed anywhere** (neither panel nor agent):
`monitor.ContainerMonitor.GetContainerStats` (`docker stats --no-stream`: CPU%, mem, net I/O,
block I/O) and `monitor.LogStreamer.SearchLogs` (`docker logs | grep -i -- PATTERN | tail -100`).

Not in ServerPlan at all: `docker exec` into a container (only for `psql` internally),
`docker inspect`, image pull/update, recreating a container outside a deploy, `docker system df`,
prune (only `docker image prune -f` after every deploy), volume prune, container health/restart
events.

## 3. What ClaudeDeck used before this change

- `ServerPlanClient` (ClaudeDeckCore): `me`, `servers`, `health`, `capabilities`, `projects`,
  `containers`, `deployments`, `deployment`, `containerLogs(tail)`, `containerLogStream(tail)`,
  `deployStream`, `eventStream`, `terminalTicket`/`terminalURL` (shell | claude), `preview` /
  `perform` for the 428 actions (deploy, container start/stop/restart), `raw` for the CLI.
- Mac app: sidebar Servers section (server rows with health line and dot, project rows, container
  rows with a context menu: Logs, Start/Stop/Restart with the server's 428 summary in a dialog),
  a logs sheet (tail, follow over SSE, 2000 lines, no search), the deploy sheet with Fix with
  Claude, server terminals and "Claude Code on server" through `ServerPlanTerminalBridge`.
- CLI (`claudedeck server …`): `containers`, `logs [--tail] [--follow]`, `container … start|stop|restart`
  (the owner's approval in the Onaylar queue), `health`, `ports`, `env get|set|rm`, `server-env`, …
- Phone: servers, failed deploys, Fix with Claude, clear errors; no containers.

## 4. What ClaudeDeck does now (this change)

Everything below works against a 1.4 panel; the items marked *(gated)* light up when `/me`
lists the feature named in section 5.

- **Container rows**: state dot (running / restarting / unhealthy / exited), image tag, uptime and
  health parsed from docker's status (`Up 2 hours (healthy)`), published ports, the domains that
  route to it (the panel's container ↔ domain rule above), the ServerPlan project it belongs to.
- **Container detail sheet**: Overview (all of the above, the project's env keys with secrets
  hidden, *(gated)* inspect data: restart count, started at, mounts, networks), Logs, Stats,
  actions.
- **Live logs**: SSE follow (the panel's `log_stream`), else polling the tail; search (case
  insensitive substring, or `re:` regex), "errors only", error / warning highlighting, stderr
  marked, pause, multi-line selection and **Claude ile düzelt** (the selected lines, or the last
  errors, go to a Claude session in the matched ClaudeDeck project with the container, server,
  image and project; same flow as a failed deploy's Fix with Claude). *(gated)* `since` / `grep`
  on the panel.
- **Stats**: server CPU / RAM / disk / load sparklines sampled from `health` while the sheet is
  open (every 10 s, numbers parsed from the panel's strings); *(gated)* per-container CPU, memory,
  network and block I/O with sparklines, and a stats column in the container list.
- **Terminals**: server SSH terminal (existing), *(gated)* container shell (`docker exec`).
- **Actions**: start / stop / restart (the panel's 428 summary in a confirmation dialog);
  *(gated)* recreate, update image, remove, prune (disk usage first). Project env view and edit
  (add / change / delete a row) for the container's project, each change confirmed.
- **CLI**: `server container SERVER CONTAINER logs|stats|inspect|status|env|start|stop|restart|recreate|pull|remove`,
  `server logs … [--since T] [--grep TEXT]` (client side until the panel filters), `server stats SERVER`,
  `server disk SERVER`, `server prune SERVER …`. Reads need no approval; start, stop, restart,
  recreate, pull, remove and prune need the owner (Onaylar queue).
- **Phone** (Mac `Feature.serverPlanContainers`): a server's containers with state and (gated)
  stats, the last log lines, and "Restart" which asks the owner on the Mac (an Onaylar card).

## 5. Missing in the agent API: requests for ServerPlan

Proposed as API **1.5**. Every one is announced by a `/me` feature (ClaudeDeck gates on the
feature, never on the version), uses the existing error shape `{"error","message"}`, the existing
`containerNameRe` check (`400 bad_request`), `404 not_found` for an unknown server or container,
and `502 server_unreachable` for SSH/docker failures. Destructive ones use `agentConfirm` (428
`{error:"confirm_required",message,summary,confirm}`) exactly like start/stop/restart.

### 5.1 `container_details`: richer container list (backward compatible)

`GET /servers/:id/containers` adds fields (old clients ignore them):

```json
[{"name":"acme-storefront","id":"3f2a9c1b7d4e","image":"acme-storefront:205","state":"running",
  "status":"Up 2 hours (healthy)","ports":"0.0.0.0:3000->3000/tcp","created":"2026-11-20 09:12:03 +0000 UTC",
  "health":"healthy","project_id":12,"project_name":"acme-storefront","domains":["shop.example.com"]}]
```

`health`: `healthy|unhealthy|starting|none` (from `{{.Status}}` or inspect); `project_*` and
`domains` with the same matching `ListContainers` does in the panel. Scope `read`.

### 5.2 `container_inspect`: one container

`GET /servers/:id/containers/:name` · scope `read` · containers.view

```json
{"name":"acme-storefront","id":"3f2a9c1b7d4e","image":"acme-storefront:205","image_id":"sha256:…",
 "state":"running","status":"Up 2 hours (healthy)","health":"healthy","exit_code":0,
 "started_at":"2026-11-20T09:12:04Z","finished_at":null,"created_at":"2026-11-20T09:12:03Z",
 "restart_count":0,"restart_policy":"unless-stopped","oom_killed":false,
 "ports":[{"private":3000,"public":3000,"type":"tcp","ip":"0.0.0.0"}],
 "networks":["traefik-network"],"mounts":[{"source":"/opt/volumes/acme","destination":"/data","rw":true}],
 "env_keys":["DATABASE_URL","PORT"],"labels":{"traefik.http.routers.acme-storefront.rule":"Host(`shop.example.com`)"},
 "project_id":12,"project_name":"acme-storefront","domains":["shop.example.com"]}
```

From `docker inspect --format '{{json .}}'`; **env values never** (keys only).

### 5.3 `container_stats`: resource usage

- `GET /servers/:id/containers/stats` (all running containers, one `docker stats --no-stream --format '{{json .}}'`)
- `GET /servers/:id/containers/:name/stats`

Scope `read` · containers.view. Numbers, not docker's display strings:

```json
[{"name":"acme-storefront","cpu_percent":1.85,"mem_used_bytes":157286400,"mem_limit_bytes":4123000000,
  "mem_percent":3.81,"net_rx_bytes":12582912,"net_tx_bytes":3145728,"block_read_bytes":0,
  "block_write_bytes":4096,"pids":11,"checked_at":"2026-11-20T11:00:00Z"}]
```

Net and block are docker's cumulative counters (ClaudeDeck derives rates between samples).
`GetContainerStats` already exists in `monitor/containers.go`; it only needs numbers and a route.

### 5.4 `server_stats`: numeric server health (backward compatible)

`GET /servers/:id/health` adds, next to the existing strings:

```json
{"cpu_percent":12.3,"cores":4,"mem_used_bytes":1288490188,"mem_total_bytes":4080218931,
 "disk_used_bytes":9663676416,"disk_total_bytes":42949672960,"load1":0.10,"load5":0.20,"load15":0.30,
 "net_rx_bytes":987654321,"net_tx_bytes":123456789,"uptime_seconds":259200}
```

(`/proc/stat` twice 200 ms apart or `top`, `free -b`, `df -B1 /`, `/proc/loadavg`, `nproc`,
`/proc/net/dev` summed over non-loopback interfaces, `/proc/uptime`.)

### 5.5 `log_query`: since / until / grep / timestamps on logs

- `GET /servers/:id/containers/:name/logs?tail=N&since=T&until=T&grep=TEXT&timestamps=1`
- `GET …/logs/stream?tail=N&since=T&timestamps=1`

`since`/`until`: RFC 3339 or a Go duration (`10m`, `2h`), passed to `docker logs --since/--until`
(validate: `^[0-9TZ:.+-]{1,40}$|^[0-9]+[smh]$`). `grep`: max 200 chars, fixed string, case
insensitive, applied as `| grep -i -F -- <shell-quoted>` (as `SearchLogs` does), and `tail`
applies after the filter. Scope `logs`.

### 5.6 `container_exec`: a shell inside a container

`POST /ws-ticket` accepts `{"server_id":1,"command":"exec","container":"acme-storefront","cols":120,"rows":40}`.
Scope `terminal` · servers.ssh **and** containers.control. The ticket stores the container
(validated with `containerNameRe`); the WebSocket runs, with a PTY,
`docker exec -it <name> sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'`.
Same protocol as the server terminal. `400 bad_request` when the container isn't running. Audit:
`terminal: server=… command=exec container=…`.

### 5.7 `container_recreate`: recreate with the same image and settings

`POST /servers/:id/containers/:name/recreate` `{"confirm":"<name>"}` · scope `containers` ·
containers.control. For a ServerPlan project container: re-run `generateDockerRunCmd` with the
project's current env and the image already on the server (no build), i.e. `docker rm -f` then
`docker run …` (env changes take effect). Other containers: `400 bad_request` "not a ServerPlan
project container". 428 summary e.g. "acme-storefront @ prod-eu-1: container yeniden olusturulur
(mevcut imaj, guncel env)". Answer `{"success":true,"id":"<new id>"}`. Publishes
`container.recreated` on `/events`.

### 5.8 `image_update`: pull a newer image and recreate

`POST /servers/:id/containers/:name/pull` `{"confirm":"<name>"}` · scope `containers`.
`docker pull <image>`; if the image ID changed, recreate as in 5.7 (with `docker run` reusing
the container's own config for non-project containers via inspect). Answer
`{"success":true,"updated":true,"old_image_id":"…","new_image_id":"…","output":"<last 20 lines of pull>"}`.
ServerPlan-built images (no registry): `400 bad_request` "imaj ServerPlan tarafindan derleniyor; deploy kullanin".

### 5.9 `container_remove`

`DELETE /servers/:id/containers/:name` `{"confirm":"<name>"}` · scope `containers` · admin
(like the panel's route). `docker rm -f`. Refuse `traefik` and the server's postgres/redis
containers (`400`). Answer `{"success":true}`.

### 5.10 `docker_prune`: disk usage and prune

- `GET /servers/:id/docker/disk` · scope `read` · servers.view_details:
  `docker system df --format '{{json .}}'` as
  `{"images":{"count":12,"active":4,"size_bytes":…,"reclaimable_bytes":…},"containers":{…},"volumes":{…},"build_cache":{…}}`
- `POST /servers/:id/docker/prune` `{"images":"dangling"|"unused"|"none","containers":true,"volumes":false,"build_cache":true,"confirm":"<server name>"}`
  · scope `containers` · admin. 428 summary names what goes and the reclaimable size;
  runs `docker container prune -f`, `docker image prune -f [-a]`, `docker builder prune -f`,
  `docker volume prune -f` (volumes only when asked; summary warns that unused named volumes
  are deleted with their data). Answer `{"success":true,"reclaimed_bytes":123456789,"output":"…"}`.

### 5.11 `container_events` (optional)

On `/events`: `container.died {server_id,server_name,name,exit_code}`, `container.unhealthy
{server_id,server_name,name}`, `container.restarted`, from `docker events` on servers where an
agent is active (like the health poller). ClaudeDeck would notify like a failed deploy.

### ClaudeDeck's gates for these

| Action | ClaudeDeck UI | `claudedeck server` (agents) |
|---|---|---|
| list, inspect, stats, logs, disk | no confirmation | no approval |
| start, stop, restart | confirm dialog (panel's 428 summary) | the owner (Onaylar queue) |
| recreate, pull, remove, prune | confirm dialog | the owner (Onaylar queue) |
| container shell | owner opens it himself | not offered to agents |
| env edit | confirm dialog per change | `server env set|rm` as before (`env rm`: the owner) |
