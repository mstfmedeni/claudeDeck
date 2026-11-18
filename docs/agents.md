# Agents

ClaudeDeck can ask other models about a Claude Code session: a bot running on this Mac (for
example a Grok Bot routine) behind a webhook, or a system prompt and model it calls through the
xAI API. An agent never types into Claude Code on its own: its answers arrive as purple notes
beside the session (on the Mac and the phone), and the user sends them on, or queues them for the
next turn. The one exception is an agent the user explicitly allows to send directly (below).

## Setup

Settings › Agents:

1. **Add Agent…** and pick where it runs:
   - **xAI API (Grok):** a new bot made of the instructions (system prompt) and a model picked from
     the API's list. Needs the xAI API key (stored in the keychain). It knows nothing beyond what
     ClaudeDeck sends.
   - **Webhook:** your existing bot. `https://…`, or `http://` only to this Mac (`127.0.0.1`,
     `localhost`). An optional `Authorization` header value is stored in the keychain; a bare token (no space)
     gets `Bearer ` in front, anything with a scheme (`Bearer …`, `Basic …`) is sent as typed.
2. **Asynchronous** (webhook only): the webhook just acknowledges (`200`/`202`) and answers later
   through the local API (`POST /v1/notes` with the `request_id`).
3. **Asks by itself…**: the agent is asked automatically when a session finishes a turn, or waits on
   a permission or a question, **only in the projects you tick** (none ticked: never). Once per turn;
   after 3 automatic rounds in a row without a message from the user it pauses (ask by hand, or write
   to Claude, to go on).
4. **May type into Claude through the local API**: off by default. Off, texts the agent sends to
   `/sessions/{id}/prompt` become notes.
5. **Local API for agents on this Mac**: on/off, port (default **47647**; the remote port 47821 is
   refused), the bearer token (Copy, Regenerate…).
6. **Activity Log…** lists everything sent to and received from agents.

Ask by hand from a session's menu (**Ask Agent**) or on the phone (**Ask** above the message field;
what's typed there is the request). **Ask Agent › Preview What's Sent…** shows the exact text first.
Notes are kept on disk (Application Support/agent-notes.json) and come back after a restart; notes
that were sent, queued or dismissed stay in **Past Reviews…** (the session's menu, last 50).

Before anything goes out, key- and token-looking strings in the messages, the diff and new files are
replaced with `[redacted]` (API keys with known prefixes, private key blocks, JWTs, bearer values,
`password=` / `secret:` style assignments). It's a safety net, not a guarantee: review what you send.

## What a webhook receives

`POST` with `Content-Type: application/json`. Every key is always present (`null` when unknown).

```json
{
  "request_id": "6F1C2A0E-0C55-4D2B-9C5A-2B0F6C7D8E91",
  "event": "session.idle",
  "agent": "Kod Checker",
  "system": "You review Swift code…",
  "model": "",
  "async": true,
  "project": { "id": "B0000000-0000-0000-0000-000000000003", "name": "mobile-app", "path": "/Users/me/Projects/mobile-app" },
  "session_id": "C0000000-0000-0000-0000-000000000005",
  "session_name": "mobile-app",
  "session_state": "idle",
  "user_request": "",
  "last_user_message": "add pull-to-refresh to the feed",
  "last_assistant_message": "Done — added pull-to-refresh…",
  "git_diff": "diff --git a/…",
  "untracked_files": [{ "path": "Sources/Feed/Refresh.swift", "content": "import SwiftUI…" }],
  "transcript_path": "/Users/me/.claude/projects/…/….jsonl",
  "timestamp": "2026-11-06T12:00:00Z",
  "message": "Review the latest work in this Claude Code session.\n\nProject: …",
  "callback": { "notes_url": "http://127.0.0.1:47647/v1/notes", "request_id": "6F1C2A0E-…" }
}
```

- `event`: `manual` (asked by the user), `session.idle`, `session.permission`, `session.question`,
  `session.claude_ask` (Claude asked through `claudedeck-ask`), `agent.test` (Settings' Test button).
- `session_state`: `idle`, `running`, `needsPermission`, `needsAnswer`, `starting`, `stopped`.
- `git_diff` is `git diff HEAD` (cut at 60 000 characters). `untracked_files` are new files git
  doesn't ignore: text only, at most 25 files, 16 000 characters each, 48 000 in all; `.env*`, keys,
  certificates and files named like secrets/tokens/credentials are never sent.
- `message` is the same context as one readable text (what an xAI agent gets).
- `callback` is `null` while the local API is off.

**Synchronous** webhooks answer with `{"reply": "…"}` or plain text (at most 1 MB; an empty reply
is an error). **Asynchronous** ones acknowledge, then post the answer to `callback.notes_url`.

## Local API

`http://127.0.0.1:<port>` (this Mac only). Every request needs `Authorization: Bearer <token>`
(compared in constant time); bodies are at most 1 MB, JSON with snake_case keys.

| Method | Path | Body | Does |
|---|---|---|---|
| GET | `/v1/projects` | | Projects and their sessions, with state |
| GET | `/v1/sessions/{id}/messages?limit=N` | | The last N transcript entries (1–200, default 20) |
| POST | `/v1/notes` | `{request_id?, session_id, agent, text}` | A note on the session; with the `request_id` of a request, its answer |
| POST | `/v1/sessions/{id}/prompt` | `{agent, text}` | Types into Claude if the agent may send directly, else a note; `409` while a permission or question is on screen |
| POST | `/v1/projects/{id}/sessions` | `{agent, name?, prompt?}` | A new Claude session; `prompt` goes in once Claude is up |

Errors are `{"error": "…"}`: `400 bad_request`, `401 unauthorized`, `403 not_registered_by_api`,
`404 not_found` / `unknown_session` / `unknown_project` / `unknown_agent`, `405 method_not_allowed`,
`409 blocked` / `not_running` / `not_started` / `name_taken`, `413 too_large`, `429 too_many_pending` /
`rejected_recently`. Agents registering themselves: [below](#agents-signing-themselves-up).

```sh
TOKEN=…   # Settings › Agents › Copy
API=http://127.0.0.1:47647

curl -H "Authorization: Bearer $TOKEN" $API/v1/projects
curl -H "Authorization: Bearer $TOKEN" "$API/v1/sessions/$SESSION/messages?limit=10"

# The answer to a request ClaudeDeck sent (asynchronous webhook):
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"request_id":"'"$REQUEST"'","session_id":"'"$SESSION"'","agent":"Kod Checker","text":"Looks good, one nit: …"}' \
  $API/v1/notes

# Straight to Claude (only if the agent may send directly; otherwise a note):
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"agent":"Kod Checker","text":"Please add a test for the empty feed."}' \
  $API/v1/sessions/$SESSION/prompt

curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"agent":"Kod Checker","name":"Review fixes","prompt":"Fix the issues in REVIEW.md"}' \
  $API/v1/projects/$PROJECT/sessions
```

## Claude asking an agent itself

A Claude session can ask an agent on its own, from its terminal:

```sh
claudedeck-ask "Grok Bot" "check the error handling in FeedModel"
claudedeck-ask all "review the last change"   # every agent Claude may ask
claudedeck-ask --list                          # which ones those are
```

- Only **approved** agents with **Claude may ask it from its session** ticked (Settings › Agents ›
  Edit…; off by default, also for agents that registered themselves) can be asked. Others answer
  `403 not_allowed`, pending ones `409 not_approved`, unknown names `404`.
- The agent gets the same request a user's Ask Agent sends, with `event: "session.claude_ask"` and
  Claude's text as `user_request`. **Its answer comes to you as a note**, marked "Claude asks"; it
  reaches Claude only if you send it on (or the agent may type into Claude).
- At most 5 asks per session in 10 minutes (`429 too_many_asks`). Every ask is in the Activity Log.
- How it works: each Claude session ClaudeDeck starts gets `CLAUDEDECK_ASK_TOKEN` (a token for that
  session only, not the API's), `CLAUDEDECK_ASK_URL` and `CLAUDEDECK_ASK` (the command's absolute
  path; it's also on `PATH`). The command posts `agent=…&request=…` (form-encoded) to `/v1/ask` on the
  local API, which must be on. Sessions started before 0.5.0 don't have these: restart them.
- Claude doesn't know about the command unless told. Tell it in a message, or add a line to the
  project's `CLAUDE.md`, for example: *"To get a second opinion, run `"$CLAUDEDECK_ASK" "Grok Bot"
  "<question>"`; the answer goes to the user."*

## Command-line tool for sessions

`claudedeck` lets a Claude session (or a terminal) work with ClaudeDeck from its own shell: open a
terminal beside itself for a dev server or a test run, type into it, read its screen, wait for it,
and notify or ask you. Turn it on in **Settings › Agents › Command-line tool for sessions** (off by
default; it needs the **Local API** on). Sessions and terminals started after that get it; restart
running ones.

```sh
claudedeck list [--json]
claudedeck open [--split right|left|down|none] [--cwd DIR] [--name NAME] [--json] [--] [COMMAND...]
claudedeck send ID TEXT [--enter] [--json]
claudedeck capture ID [--lines N] [--trim] [--json]
claudedeck wait ID [--timeout SECONDS] [--json]
claudedeck notify TEXT
claudedeck ask [--agent NAME] QUESTION
claudedeck skill setup [--user|--project] [--force]
```

- `ID` is an id from `list`, a unique prefix of one (at least 4 characters; `list` shows 8), or `self`.
- **list:** every session and terminal: id, kind (`claude`/`terminal`), state, pane (1 = leftmost,
  `-` when not on screen) and whose it is (`self`, `mine` for terminals it opened). A terminal's
  state is `running` (a command has the terminal), `idle` (at its prompt), `failed` (its first
  command exited non-zero), `blocked` (its program says it waits for you; terminals with Program
  Status) or `stopped`; a Claude session's is as in `/v1/projects`.
- **open:** a plain terminal in the session's project, in the session's folder (or `--cwd`), running
  `COMMAND`; prints the new id. One argument is a shell command line (`"npm run dev && open …"`),
  several are run as given. The terminal goes in a pane beside the caller when the caller is on
  screen and there's room (at most 4 panes; `down` is placed like `right`, since panes sit side by
  side; `none` never shows it). Your selection stays where it was. Otherwise it runs in the sidebar
  only (`"shown": false`). It's an ordinary terminal afterwards: its command is its startup command
  (run again when you restart it, never on launch), and the shell stays when the command ends.
- **send:** types `TEXT` (`-` reads stdin); `--enter` presses Return after it. See the rule below.
- **capture:** the screen and up to 1000 lines of scrollback (or `--lines N`, the last N), trailing
  spaces cut; `--trim` also drops blank lines at the top and bottom.
- **wait:** until the terminal's command finishes, or a Claude session is idle or needs you. A
  command `open` started reports its exit code. After `send --enter` into a terminal, it waits until
  no other process has the terminal, the shell is back in its line editor (zsh, bash; at most 30 s
  for shells without one, like `sh`) and the output has settled; a typed command's exit code isn't
  known (`finished`). After a send to a Claude session, only a newer hook state counts. A
  terminal with Program Status answers from it: blocked ends the wait with 3, and a typed command's
  result (shell integration) gives its exit code. No `--timeout` (or `0`): no limit.
- **notify:** a notification (unless notifications are off in Settings). **ask:** a note beside the
  session ("claudedeck ask") and a notification; with `--agent`, the agent is asked under
  `claudedeck-ask`'s rules. At most 10 notifications, questions and notes in 10 minutes per session.
- **skill setup:** writes a Claude Code skill (`SKILL.md`) explaining the command to
  `~/.claude/skills/claudedeck/` (`--user`, the default; `$CLAUDE_CONFIG_DIR` if set) or the
  repository's `.claude/skills/claudedeck/` (`--project`). The last line holds a hash of what
  ClaudeDeck wrote; a file changed by hand (or written by you) is left alone unless `--force`.

**Exit codes** (stable):

| Code | Meaning |
|---|---|
| 0 | OK; `wait`: the command exited 0, the Claude session is idle, or the target isn't running |
| 1 | `wait`: the command failed (its code is printed); otherwise an error (API off, not running…) |
| 2 | Bad arguments, or not inside a ClaudeDeck session |
| 3 | `wait`: the Claude session needs you (a permission or a question), or the terminal's program does (Program Status); `send`: one is on screen |
| 4 | Refused: the session's token doesn't allow it, the tool or the command's setting is off, too many requests, a rate limit or cap, the owner said no, or ServerPlan doesn't offer it |
| 5 | Unknown id, project, server, container or deployment |
| 124 | `wait` timed out; still running |

**Who may do what.** Each terminal gets its own token (`CLAUDEDECK_CLI_TOKEN`; never the API's
token, and the API's token isn't accepted here). Its scopes:

| Terminal | list | open | send | capture | wait | notify | ask | projects | start | server |
|---|---|---|---|---|---|---|---|---|---|---|
| A Claude session, or a terminal you opened | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| A terminal a session opened with `claudedeck open` | ✓ | | | ✓ | ✓ | ✓ | | | | |

`start` (project add, new) and `server` also need their settings (below).

`send` types into a plain terminal the caller opened, or one in a pane beside it. Another Claude
session gets the text **as a note** unless **May type into Claude: sessions may send text to other
Claude sessions** is on (off by default); then it's typed like `/v1/sessions/{id}/prompt` would
(`409` while a permission or question is on screen). Anyone else's terminal, and the caller itself,
are refused. The output starts with what happened: `terminal:`, `claude:` or `note:`.

**Environment.** While the setting is on, every terminal ClaudeDeck starts gets `CLAUDEDECK_SESSION`
(its session id; a pane shows one session, so there's no separate pane id), `CLAUDEDECK_CLI_TOKEN`,
`CLAUDEDECK_CLI_URL` (`http://127.0.0.1:<port>/v1/cli`) and `CLAUDEDECK_CLI` (the command's absolute
path; its folder is also put first on `PATH`). The command is a shell script written to
Application Support/ClaudeDeck/bin/claudedeck; it holds no secret.

**Routes.** The command is a thin client of these (form-encoded bodies, as `curl --data-urlencode`
sends; `format=json` for JSON, otherwise text). Every answer has `X-ClaudeDeck-Exit` with the exit code.
Off, they answer `404 not_found`.

| Method | Path | Parameters | Scope |
|---|---|---|---|
| GET | `/v1/cli/sessions` | | list |
| POST | `/v1/cli/terminals` | `command, cwd, name, split` | open |
| POST | `/v1/cli/sessions/{ref}/send` | `text, enter=1` | send |
| GET | `/v1/cli/sessions/{ref}/screen` | `lines, trim=1` | capture |
| GET | `/v1/cli/sessions/{ref}/wait` | `timeout` (seconds, at most 25 per request) | wait |
| POST | `/v1/cli/notify` | `text` | notify |
| POST | `/v1/cli/ask` | `question, agent` | ask |
| GET | `/v1/cli/projects` | | projects |
| POST | `/v1/cli/projects` | `path, name, group, create=1` | start |
| POST | `/v1/cli/projects/{ref}/sessions` | `name, prompt, worktree` | start |
| GET/POST | `/v1/cli/server/{command}` | per command (below) | server |

Errors: `400 bad_request` / `bad_split` / `bad_cwd` / `too_long` / `ambiguous` / `cannot_send_to_self` /
`cannot_wait_for_self`, `401 unauthorized`, `403 not_allowed` (scope) / `not_yours`, `404 unknown_session`,
`409 not_running` / `blocked` / `not_started`, `429 too_many`; for the commands below also
`403 setting_off` / `system_path` / `outside_home` / `owner_refused` / `serverplan_off`,
`404 unknown_project` / `no_such_folder`, `429 too_many_starts` / `too_many_projects` /
`too_many_running`, `501 not_available`. The routes for agents above (`/v1/projects`,
`/v1/sessions/{id}/prompt`, …) are unchanged.

### Projects and Claude sessions

```sh
claudedeck projects [--json]
claudedeck project add PATH [--name NAME] [--group GROUP] [--create] [--json]
claudedeck new [--project ID|NAME|PATH] [--name NAME] [--prompt TEXT] [--worktree NAME] [--json]
```

They need **Sessions may add projects and start Claude sessions** (Settings › Agents ›
Command-line tool; off by default, exit 4 `setting_off`). When it's on there's no prompt per action.

- **projects:** id, name, path, group and number of sessions.
- **project add:** adds a folder like Add Project and prints the project's id. A folder that is
  already a project answers with that project (exit 0, `"existing": true`). The path is resolved
  (`..`, symlinks); `/` and system folders (`/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/Library`,
  `/Applications`, `/dev`, `/Volumes`, …) are refused. `--create` makes a missing folder, only below
  the user's home (not `~/Library` or a dot folder; a demo also allows its own folder). `--group`
  puts it in that group, made if needed.
- **new:** a Claude session in the project (`self`, the default: the caller's project; or an id,
  a unique prefix, a name, a path), through the same start as **New Claude Session** (or a
  worktree session with `--worktree`). `--prompt` is typed once Claude's hooks say it's up (at
  most 60 s). Prints the session id; `wait`, `capture` and `send` work on it. The owner's selection
  stays where it was. The session records who started it (`startedBy`): the caller may `send` to
  it without **May type into Claude**. Unknown project: exit 5.
- **Folder trust:** Claude Code asks "Is this a project you created or one you trust?" the first
  time it runs in a folder, and nothing happens (hooks included) until someone answers, so a
  session started with `new` in a fresh folder would just sit there. Before it launches, ClaudeDeck
  marks the folder trusted the way that answer does: `projects[<folder>].hasTrustDialogAccepted`
  in Claude Code's config (`~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`). Only for
  sessions started with `new`, with the setting on, and only for a folder `--create` could make:
  absolute, below the home folder (not the home itself), not `~/Library`, no dot folder in it,
  never a system folder. Claude Code's own processes rewrite that file, so the change is made the
  way they make theirs: under their lock (`~/.claude.json.lock`, waited for up to 3 s, never
  broken), from a fresh read, inserted into the text so every other byte stays, checked (the
  result must be the old config plus that key), written to a temporary file and renamed over the
  original only if the file is unchanged since the read (inode, size, modification time),
  otherwise read and done again. Nothing is written when the file isn't a JSON object. It's in
  the Activity Log and the notification ("… and trusted its folder"); when it can't be done, the
  notification says Claude Code is asking. Sessions the owner starts keep asking as before. The
  demo uses its own `~/.claude.json` (in its home), never the real one, and its stand-in `claude`
  shows the question in folders that aren't trusted.
- **Guardrails:** per calling session at most 5 `new` in 10 minutes and 10 new projects an hour;
  at most 8 sessions started this way running at once (all callers). Over a limit: `429`, exit 4.
  Every action is in the agent Activity Log, and the owner gets a notification "started Y in Z"
  (what one session does within 3 s is one notification). Terminals a session opened with
  `claudedeck open` don't have these scopes (`403 not_allowed`).

### ServerPlan (`claudedeck server …`)

They need **Sessions may use ServerPlan** (off by default) and ServerPlan set up in ClaudeDeck
(else exit 4, `serverplan_off`). The command never gets the ServerPlan token: the app runs each
command with `ServerPlanClient` and the token from the Keychain. `--json` passes the panel's JSON
through (secret values removed); text output reads it tolerantly. The table of commands, the client
calls they make and their 428 handling is `ServerPlanCLI.commands` (ClaudeDeckCore/ServerPlanCLI.swift).

| Command | Panel call | On a 428 |
|---|---|---|
| `server list` · `projects` · `deployments [--project P]` | `GET /servers` · `/projects` · `/deployments` | |
| `server health SERVER` · `containers SERVER` | `GET /servers/:id/health` · `/containers` | |
| `server logs SERVER CONTAINER [--tail N] [--follow]` | `GET …/logs`; `--follow` the log stream, 25 s per request | |
| `server deploy PROJECT [--server S] [--force] [--wait]` | `POST /projects/:id/deploy` | confirmed automatically, logged |
| `server deploy-status ID [--wait]` | `GET /deployments/:id` (long poll with `--wait`) | |
| `server container SERVER CONTAINER start\|stop\|restart` | `POST …/containers/:name/:verb` | the owner's dialog |
| `server features` | `GET /me` | |
| `server dirs` · `scan DIR-ID\|PATH` | `GET /project-dirs` · `POST /project-dirs/:id/scan` | |
| `server ports SERVER` | `GET /servers/:id/ports` | |
| `server project show\|set PROJECT [--server S] [--port N] [--volume P] [--dockerfile P]` | `GET`/`PUT /projects/:id/settings` (set sends the current values merged with the new ones) | |
| `server env get\|set PROJECT` | `GET /projects/:id/env` · `POST …/env/bulk` | |
| `server dockerfile template\|write PROJECT` | `GET …/dockerfile/template` · `POST …/dockerfile` | |
| `server db create PROJECT` | `POST /projects/:id/auto-create-db` | |
| `server domain list [--server S]` · `domain add PROJECT SUB BASE [--server S] [--port N] [--websocket] [--target T]` | `GET`/`POST /domains` | the owner's dialog (replacing an A record) |
| `server dns sync DOMAIN` | `POST /domains/:id/dns-sync` | the owner's dialog |
| `server cloudflare` · `zone add NAME` | `GET /cloudflare/status` · `POST /cloudflare/zones` | |
| `server ns set DOMAIN` | `POST /domains/:id/namecheap/nameservers` | the owner's dialog (custom nameservers) |

- SERVER, PROJECT, DOMAIN: an id or a name (FQDN for domains). `scan PATH` scans the registered dir
  the path is in and, for a project's own folder, prints that project.
- **Deploys are autonomous:** if the panel asks for a confirmation (v1), the app sends it and logs
  "confirmed automatically". `deploy --wait` prints the deployment id, then new log lines and status
  changes, and exits 0 on success or 1 on failure (with the error). Every other 428 shows the
  owner a dialog in the app (and a notification); refused, or no answer within 2 minutes: `403
  owner_refused`, exit 4. The command waits up to 150 s for it.
- **v1.1 commands** (`dirs`, `scan`, `ports`, `project`, `env`, `dockerfile`, `db`, `domain`,
  `dns`, `cloudflare`, `zone`, `ns`): a panel whose `/me` lacks the command's scope
  (`projects_write`, `databases`, `domains`, `dns`), or that answers 404 for a read-only one,
  answers `501 not_available` ("not available: ServerPlan doesn't offer this yet"), exit 4.
- `env set` takes `KEY=VALUE` lines from `--from-file FILE` or stdin (`-`) so secrets stay out of the
  shell history; `--secret KEY` marks secrets. Values are never printed, only the keys.
- Reads aren't logged one by one (`--wait` polls); every change and every refusal is in the
  Activity Log.

## Agents signing themselves up

A bot can add itself instead of being typed into Settings: it registers through the local API
(same token), then waits until you approve it. Until then it gets **no** webhook, isn't in
**Ask Agent** (Mac or phone) and can't type into Claude.

| Method | Path | Body | Does |
|---|---|---|---|
| POST | `/v1/agents` | `{name, kind: "webhook", url?, auth_header?, async?, description?}` | Registers it as pending: `201 {agent_id, status: "pending", needs}` |
| GET | `/v1/agents` | | Every agent: `[{id, name, kind, url_host, status, async, registered, needs}]` |
| GET | `/v1/agents/{id}` | | One agent (poll it to see whether you approved it) |
| DELETE | `/v1/agents/{id}` | | Removes an agent that registered itself (`403` for ones added in Settings) |

- `name`: 1–40 characters, not blank, one line. `kind`: only `"webhook"`. `url` (optional, see
  below): `https://…`, or `http://` only to this Mac (`127.0.0.1`, `localhost`). `description` (at most 500 characters) is
  shown when you decide; it's never sent anywhere.
- `auth_header` goes to the keychain, like the header of a webhook agent added by hand; it's never
  written to deck.json or the activity log, and no endpoint returns it. Listings show the URL's host
  only (`url_host`), never its path or query. `kind` is `xai` for Grok bots made in Settings.
- `status`: `pending`, `approved` or `rejected`. `registered` is `true` for agents that signed
  themselves up (only those can be deleted through the API).
- **Idempotent:** the same name (case-insensitively) and URL again answers `200` with the agent
  already there and its status. The same name with another URL is `409 name_taken`. Without a URL
  the name alone identifies it: registering again returns the same record.
- `needs`: what you still have to fill in before approving: `["url", "auth_header"]` for an agent
  that registered without a URL (`["url"]` if it sent a header), `[]` otherwise and once approved.
- `auth_header` (and the header you paste) must be one line of printable ASCII, at most 4096
  characters.
- Bodies are at most 16 KB (`413 too_large`); bad JSON is `400 bad_request`. Other `400`s:
  `bad_name`, `bad_kind`, `bad_url`, `insecure_url`, `bad_auth_header`, `bad_description`.
- At most 10 agents wait at once (`429 too_many_pending`). A rejected name and URL can't register
  again for 24 hours (`429 rejected_recently`); `GET /v1/agents/{id}` says `rejected` meanwhile, and
  `DELETE` refuses it (`429 rejected_recently`) so the wait can't be skipped.

**Grok Bot agents (no URL).** A Grok Bot routine can't see its own webhook URL or Authorization
header; only you can copy them from the routine's panel. So it registers **without `url`**, and you
paste both when approving: the approval form (the notification opens it, and it's in Settings ›
Agents, the sidebar and on the phone) shows **Webhook URL** and **Authorization header** fields with
**Paste from Clipboard**. They're checked as you paste (https except to this Mac; a one-line header)
and **Approve** stays off until both are valid. Approving saves the URL, puts the header in the
keychain (never in deck.json or the log; from the phone it travels over the encrypted remote
connection) and the agent is approved. `GET /v1/agents/{id}` then says `approved`, `url_host` is the
URL's host, and the header is never returned.

```sh
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Grok Reviewer","kind":"webhook","async":true,"description":"Reviews Swift diffs"}' \
  $API/v1/agents
# → {"agent_id":"5A0C…","needs":["url","auth_header"],"status":"pending"}
```

**Approval.** A new registration shows a notification on the Mac (with **Approve** / **Reject**),
an **Agents Waiting for Approval** section in Settings › Agents and above the sidebar's waiting tray (name, URL host, description), and
the same section at the top of the phone's session list. Approved, it's an ordinary webhook agent:
it gets requests, shows in Ask Agent, and you can edit it in Settings. **May type into Claude** stays
off and no project is ticked for automatic requests until you change them. Registrations,
approvals, rejections and deletions are in the **Activity Log…**.

```sh
# Register (once; running it again is harmless):
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Kod Checker","kind":"webhook","url":"https://bots.example.com/kod-checker",
       "auth_header":"Bearer '"$BOT_SECRET"'","async":true,"description":"Reviews Swift diffs"}' \
  $API/v1/agents
# → {"agent_id":"9A3F…","status":"pending"}

# Approved yet?
curl -H "Authorization: Bearer $TOKEN" $API/v1/agents/$AGENT_ID
# → {"id":"9A3F…","name":"Kod Checker","kind":"webhook","needs":[],"url_host":"bots.example.com","status":"approved",…}

# Leave:
curl -X DELETE -H "Authorization: Bearer $TOKEN" $API/v1/agents/$AGENT_ID
```

The agent name in API calls is matched (case-insensitively) against the agents in Settings; only
those can send directly. A name that isn't there still gets its texts in as notes.
