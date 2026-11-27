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
claudedeck send ID TEXT [--enter|--no-enter] [--json]
claudedeck capture ID [--lines N] [--trim] [--json]
claudedeck wait ID [--timeout SECONDS] [--json]
claudedeck wait --all|--any ID... [--timeout SECONDS] [--json]
claudedeck close ID|self [--force] [--remove|--keep] [--json]
claudedeck remove ID [--json]
claudedeck restart ID [--json]
claudedeck resume ID [--prompt TEXT|-] [--queue] [--json]
claudedeck compact [ID|self] [--json]
claudedeck remote-control off ID|self|--all [--no-wait] [--json]
claudedeck notify TEXT
claudedeck ask [--agent NAME] QUESTION
claudedeck decide QUESTION [--options "A,B,C"] [--recommend A] [--context TEXT] [--project P] [--supersedes ID] [--json]
claudedeck decision get ID [--json]
claudedeck decision cancel ID [--reason TEXT] [--json]
claudedeck decisions [--pending] [--json]
claudedeck account list|current [--json]
claudedeck account switch [--to NAME] [--json]
claudedeck status [ID] [--json]
claudedeck usage [--project ID|NAME|PATH] [--json]
claudedeck skill setup [--user|--project] [--force]
```

- `ID` is an id from `list`, a unique prefix of one (at least 4 characters; `list` shows 8), or `self`.
- **list:** every session and terminal: id, kind (`claude`/`terminal`), state, pane (1 = leftmost,
  `-` when not on screen) and whose it is (`self`, `mine` for terminals it opened). A terminal's
  state is `running` (a command has the terminal), `idle` (at its prompt), `failed` (its first
  command exited non-zero), `blocked` (its program says it waits for you; terminals with Program
  Status) or `stopped`; a Claude session's is as in `/v1/projects`, plus `limit_reached` (it
  stopped on its plan's usage limit and waits for the reset; `limit_resets_at` says when) and
  `switching_account` (it is being moved to another account, or is about to be: see
  [Claude accounts](#claude-accounts-and-usage-limits)). `--json` also has `account` (the
  Claude account a Claude session runs on; null for terminals) and `limit_resets_at`.
- **open:** a plain terminal in the session's project, in the session's folder (or `--cwd`), running
  `COMMAND`; prints the new id. One argument is a shell command line (`"npm run dev && open …"`),
  several are run as given. The terminal goes in a pane beside the caller when the caller is on
  screen and there's room (at most 4 panes; `down` is placed like `right`, since panes sit side by
  side; `none` never shows it). Your selection stays where it was. Otherwise it runs in the sidebar
  only (`"shown": false`). It's an ordinary terminal afterwards: its command is its startup command
  (run again when you restart it, never on launch), and the shell stays when the command ends.
- **send:** types `TEXT` (`-` reads stdin). Into a Claude session it is submitted (queued while
  Claude works) unless `--no-enter`; into a plain terminal Return is pressed only with `--enter`.
  See the rule below.
- **capture:** the screen and up to 1000 lines of scrollback (or `--lines N`, the last N), trailing
  spaces cut; `--trim` also drops blank lines at the top and bottom.
- **wait:** until the terminal's command finishes, or a Claude session is idle or needs you. A
  command `open` started reports its exit code. After `send --enter` into a terminal, it waits until
  no other process has the terminal, the shell is back in its line editor (zsh, bash; at most 30 s
  for shells without one, like `sh`) and the output has settled; a typed command's exit code isn't
  known (`finished`). After a send to a Claude session, only a newer hook state counts. A
  terminal with Program Status answers from it: blocked ends the wait with 3, and a typed command's
  result (shell integration) gives its exit code. No `--timeout` (or `0`): no limit. `ID` may
  be a queue id from `new --queue` (`q_…`): it waits for the start (`timeout: still queued`,
  124), then for the session; a start that was cancelled or failed is exit 1
  (`queue_cancelled` / `queue_failed`). A Claude session that stopped on its usage limit ends
  the wait with **6** (`limited`; `--json` adds `resets_at`) while it waits for the reset; one
  that ClaudeDeck moves to another account keeps counting as running, so the wait goes on.
- **wait --all|--any:** the same over several ids (sessions, terminals or queue ids; at most 50).
  `--all` ends once every one has stopped running (idle, needs you, finished, failed, limited
  or stopped): exit 3 if any needs you, else 6 if any waits for its usage limit, else 1 if any
  failed (or its queued start won't come), else 0. `--any` ends at the first one, with that one's exit code (the first in the order
  given when several did). Timeout: 124. One line per id (`--json`: `{mode, result, first,
  sessions: [{ref, id, queue_id, result, exit_code, state, detail}]}`). Every id is checked
  first: an unknown one is exit 5, `self` exit 2.
- **close:** ends a session the way End Session does, and closes its pane (and by default
  removes it from the list); **remove:** removes one that has already stopped; see
  [Closing sessions](#closing-sessions) below. **restart:** stops a terminal's process and
  re-runs its command in the same pane; see [Restarting terminals](#restarting-terminals).
  **resume:** restarts a stopped (or removed) Claude session it started with its conversation;
  see [Resuming sessions](#resuming-sessions). **compact:** types `/compact` into itself (the default) or a Claude session it started; see
  [Compacting](#compacting). **remote-control off:** asks the owner to turn Claude Code's
  Remote Control off; see [Remote Control](#remote-control).
- **notify:** a notification (unless notifications are off in Settings). **ask:** a note beside the
  session ("claudedeck ask") and a notification; with `--agent`, the agent is asked under
  `claudedeck-ask`'s rules. At most 10 notifications, questions and notes in 10 minutes per session.
- **decide**, **decision get**, **decision cancel**, **decisions:** a decision for the owner that doesn't block; see
  [Decisions](#decisions-for-the-owner) below.
- **account list|current|switch:** the Claude accounts; see
  [Claude accounts](#claude-accounts-and-usage-limits) below.
- **status:** one session's state and detail, its project, who started it (`startedBy`), the
  stall watch's view of it (below) and the simulators it holds. Without `ID`: the caller.
- **usage:** each project's part of the plan's usage; see [Usage per project](#usage-per-project).
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
| 5 | Unknown id, project, server, container, deployment, skill, queue id, decision or account |
| 6 | `wait`: the Claude session stopped on its plan's usage limit and waits for the reset (a session being moved to another account isn't this: it counts as running) |
| 75 | an owner approval is still pending: `server … --no-wait` (prints `pending approval a_…`), or `approval wait --timeout` ran out. The command goes on in ClaudeDeck once the owner answers. |
| 124 | `wait` timed out; still running; `close`: Claude was still there 15 s after `/exit` (`remove` on a running session is exit 1 `still_running`: close it) |

**Who may do what.** Each terminal gets its own token (`CLAUDEDECK_CLI_TOKEN`; never the API's
token, and the API's token isn't accepted here). Its scopes:

| Terminal | list | open | send | capture | wait | notify | ask | projects | start | server | decide | simulators | usage | close | account | slots | restart | compact | remoteControl | projectRename |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A Claude session | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| A terminal you opened | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| A terminal a session opened with `claudedeck open` | ✓ | | | ✓ | ✓ | ✓ | | | | | | | ✓ | | | ✓ | | | | |

`projectRename` (`project rename`) also needs the caller's own project to be a coordinator
project (below).

`account list` and `account current` need `list`; `account switch` needs `account`.

`start` (project add, new, resume), `server`, `simulators` (sim) and `close` also need their settings (below).
`status` and `load` are under `list`; `slot` and `heavy` need `slots`.

`send` types into a plain terminal the caller opened, or one in a pane beside it. Another Claude
session gets the text **as a note** unless **May type into Claude: sessions may send text to other
Claude sessions** is on (off by default); then it's typed like `/v1/sessions/{id}/prompt` would
(`409` while a permission or question is on screen). Anyone else's terminal, and the caller itself,
are refused. The output starts with what happened: `terminal:`, `claude:` or `note:`. A stopped
Claude session the caller may resume (see [Resuming sessions](#resuming-sessions)) is resumed
for the text when a session closed it: `resumed:` or `resume_queued:` (`--json`:
`{"delivered":"resumed"}`, `{"delivered":"resume_queued","queue_id":"q_…"}`).

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
| GET | `/v1/cli/sessions/{ref}/wait` | `timeout` (seconds, at most 25 per request); `{ref}` may be a queue id | wait |
| GET | `/v1/cli/wait` | `ids` (comma-separated), `mode` (`all`/`any`), `timeout` | wait |
| POST | `/v1/cli/notify` | `text` | notify |
| POST | `/v1/cli/ask` | `question, agent` | ask |
| GET | `/v1/cli/projects` | | projects |
| POST | `/v1/cli/projects` | `path, name, group, create=1` | start |
| POST | `/v1/cli/projects/{ref}/sessions` | `name, prompt, worktree, permission_mode, allow, model, effort, skill, account, queue=1` (`allow`: one rule per line) | start |
| GET | `/v1/cli/presets` | | start |
| GET/POST | `/v1/cli/projects/{ref}/preset` | POST: `permission_mode, allow, model, effort` or `clear=1` | start |
| GET | `/v1/cli/queue` · `/v1/cli/queue/{id}` | | start |
| POST | `/v1/cli/queue/{id}/cancel` | | start |
| GET/POST | `/v1/cli/server/{command}` | per command (below) | server |
| POST | `/v1/cli/decisions` | `question, options, recommend, context, project, supersedes` | decide |
| GET | `/v1/cli/decisions` | `pending=1` | decide |
| GET | `/v1/cli/decisions/{id}` | | decide |
| POST | `/v1/cli/decisions/{id}/cancel` | `reason` | decide |
| GET | `/v1/cli/accounts` · `/v1/cli/accounts/current` | | list |
| POST | `/v1/cli/accounts/switch` | `to` (empty or `auto`: the first account with room) | account |
| GET | `/v1/cli/sessions/{ref}/status` | | list |
| GET | `/v1/cli/usage` | `project` | usage |
| GET | `/v1/cli/sim` | | simulators |
| POST | `/v1/cli/sim/acquire` | `device, duo=1` | simulators |
| POST | `/v1/cli/sim/release` | `udid` (empty: all of the caller's) | simulators |
| POST | `/v1/cli/sessions/{ref}/close` | `force=1`, `remove=1`, `keep=1`; `{ref}` may be a started queue id | close |
| POST | `/v1/cli/sessions/{ref}/remove` | `{ref}` may be a started queue id | close |
| POST | `/v1/cli/sessions/{ref}/restart` | `{ref}` may be a started queue id | restart |
| POST | `/v1/cli/sessions/{ref}/compact` | `{ref}` may be `self` or a started queue id | compact |
| POST | `/v1/cli/sessions/{ref}/resume` | `prompt`, `queue=1`; `{ref}` may be a removed session's id (or a unique prefix) | start |
| POST | `/v1/cli/remote-control/off` | `target` (a session ref, `self`, or `all`); 202 `pending approval a_…` (exit 75) until the owner answers | remoteControl |
| GET | `/v1/cli/load` | | list |
| POST | `/v1/cli/slot/build/acquire` | `ticket` (wait in line), `timeout` (seconds, at most 25 per request), `label` | slots |
| POST | `/v1/cli/slot/build/release` | `id` (empty: all of the caller's), or `ticket` (leave the line) | slots |

Errors: `400 bad_request` / `bad_split` / `bad_cwd` / `too_long` / `ambiguous` / `cannot_send_to_self` /
`cannot_wait_for_self`, `401 unauthorized`, `403 not_allowed` (scope) / `not_yours`, `404 unknown_session`,
`409 not_running` / `blocked` / `not_started`, `429 too_many`; for the commands below also
`403 setting_off` / `system_path` / `outside_home` / `owner_refused` / `serverplan_off`,
`404 unknown_project` / `no_such_folder`, `429 too_many_starts` / `too_many_projects` /
`too_many_running`, `501 not_available`; for `new`, `preset`, `queue` and `wait --all|--any`
also `400 bad_permission_mode` / `bad_allow` / `bad_model` / `bad_effort` / `bad_skill` /
`bad_mode`, `403 bypass_off`, `404 unknown_skill` / `unknown_queue_id`, `409 queued` /
`not_queued` / `queue_cancelled` / `queue_failed`, `429 too_many_queued`; for decisions `400 bad_recommend` / `too_many_options`,
`403 not_yours`, `404 unknown_decision`, `409 already_answered` / `already_cancelled`, `429 too_many_pending`; for `sim` `404 unknown_device` / `no_runtime` / `not_held`,
`429 too_many_simulators`, `500 simctl_failed` (with `message`); for `close` `403 close_off` / `not_yours`,
`409 busy` / `blocked` / `still_running` (exit 124) / `read_only` / `not_closed` / `switching_account`; for `remove`
`403 close_off` / `not_yours`, `409 still_running` (exit 1) / `switching_account`; for `restart`
`400 cannot_restart_self`, `403 restart_off` / `close_off` / `not_yours`, `404 unknown_session`,
`409 read_only` / `busy` / `not_running` / `not_restarted` / `switching_account`; for `compact` `400 not_claude`,
`403 not_yours`, `404 unknown_session`, `409 read_only` / `blocked` / `not_running` / `switching_account`; for
`resume` `400 not_claude` / `too_long`, `403 setting_off` / `not_yours`, `404 unknown_session`, `409 running` /
`not_resumable` / `switching_account` / `busy`, `429 too_many_running` / `too_many_starts` / `overloaded` /
`busy` / `too_many_queued`; for
`remote-control off` `400 not_claude`, `403 owner_refused` / `approval_expired`, `404 unknown_session`; for accounts `400 not_claude`, `404 unknown_account`,
`409 no_account` / `same_account` / `not_logged_in` / `account_limited` / `pinned` / `switching`; while the Mac is
overloaded (below) `429 overloaded` for `new` and `sim acquire`, and `429 too_many_booted` for `sim acquire`; for slots
`400 bad_ticket`, `404 unknown_slot` / `unknown_slot_id`, `429 no_slot` (exit 124, with `position`, `used`,
`capacity`). The routes for agents above (`/v1/projects`, `/v1/sessions/{id}/prompt`, …) are unchanged.

### The Mac's load and build slots

Many sessions share one Mac; thirty compiles, a dozen simulators and forty Claude sessions with
their MCP servers can push it to a load of 1,000, where ClaudeDeck itself stops answering.
ClaudeDeck samples the system every 12 seconds off the main thread (load average, memory
pressure and use, swap, booted simulators counted as `launchd_sim` processes, running builds and
the compiler and linker processes under them, the process count, its own running Claude sessions)
and derives a level:

**Builds, not compiler processes.** One `xcodebuild` or `swift build` runs one `swift-frontend` per
core, so the compiler process count (45 with 2–3 builds on a 20-core Mac) says nothing about how
many builds run. A build is one running build driver, found with one pass over the process table
(pid, parent, name):

- `xcodebuild` and `swift-build` always count (also while resolving packages or running tests);
- `swiftc` / `swift-driver` / `clang` / `clang++` count when started on their own (`swiftc a.swift`);
- Xcode.app's build service (`SWBBuildService`, older `XCBBuildService`), `swift test` / `swift run`
  and `cmake` / `make` / `ninja` count only while compiler processes run under them (the build
  service stays alive idle; `swift test` goes on running the tests);
- any of these counts only when none of them is above it, so `xcodebuild → SWBBuildService →
  swift-frontend × 20` is one build; compiler processes with none of them above count once per
  parent process;
- Gradle and the Kotlin daemon are not counted: they run as `java` and compile inside the JVM.

Two levels, two meanings: `busy` is **informational** by default (nothing waits; it can be set to
hold new work); `overloaded` means a real risk of the Mac locking up: new work waits and
**calming rules** kick in. Each overload trigger has its own switch and value in
Settings › Resources ("Ne zaman fren yapılsın?"), shown there with its live value (red while it
fires):

| Trigger (`triggers[].trigger`) | Default |
|---|---|
| `pressure` | macOS memory pressure **critical** (or, by the setting, high/warning) |
| `swap_growth` | swap grows by more than **2 GB within 5 minutes** while memory pressure is warning or worse |
| `swap_size` | swap above 64 GB (**off** by default: a big swap alone doesn't freeze the Mac) |
| `compilers` | more than **a third of the cores** in builds at once (at least 3; 7 on a 20-core Mac; settable 1–64), counted steady: the median of the last 3 samples (a short build shows in one sample only), and only with a busy load or memory pressure. The name stays `compilers`; until 0.6.24 it counted compiler processes (`unit` was `processes`, now `builds`) |
| `load` | the 1-minute load above **10 × cores** (200 on a 20-core Mac) for **3 minutes** |
| `processes` | more than **3,000** processes |

| Level | When |
|---|---|
| `overloaded` | any switched-on trigger fires |
| `busy` | the load above **2 × cores** for a minute, memory pressure warning, or more than half the build limit (steady count; 4 builds on a 20-core Mac). **Informational** by default (Settings › Resources › "Meşgulken" on "Sadece göster"): nothing waits, every build slot is handed out. With "Yeni işleri beklet" (and the brake on) new work waits: `new` answers `429 busy` (exit 4) or, with `--queue`, queues (reason `busy`), the start queue doesn't drain, `sim acquire` answers `429 busy`, and build slots drop to half, rounded up (more than while overloaded when there are enough). Running agents get no message either way. Booted simulators never make the Mac busy: their cap only refuses `sim acquire` |
| `ok` | otherwise |

Hysteresis: overloaded ends once no trigger fires and the load and process count have stayed
under 80–90 % of their limits for a minute (its own margins, not busy's); busy ends after 30 calm
seconds. The level never stays frozen at overloaded: once its calm minute has run out it counts as
ended even if the next sample is late, and `claudedeck load` samples afresh when the latest is
older than 30 s. While overloaded with nothing firing, `claudedeck load` says why on the line under
`level:` (`exiting: 48 s left (…); last fired 24 s ago: pressure`, or `exit held: load 170.0 not
yet under 160.0 (exit margin)`; JSON `exit_in`, `exit_blocked_by`, `last_fired`, `last_fired_ago`,
`sample_age`). The calming rules stop the moment the Mac leaves `overloaded`; busy's waiting goes
on while it is still busy. An **episode** starts when the level becomes `overloaded` and ends when it is back
to `ok` (a Mac swinging between busy and overloaded is one episode). Per episode, once: a
notification on the Mac and on paired phones listing what's behind it ("11 simülatör açık, 30
derleme, 37 oturum"), and a **message queued for every running Claude session another session
started**: `[ClaudeDeck] Mac aşırı yüklü: ağır işleri (derleme, simülatör) ertele, bitmiş
simülatörleri bırak.` It goes through the session's message queue, so it is typed only once the
session is idle (between turns, never interrupting one), and not again while a copy still waits.

Settings saved by 0.6.12 or earlier with the first defaults (overloaded at 2 × cores, busy at
1 × cores) move to the new ones when read; values the owner had changed are kept. Settings saved
by 0.6.24 or earlier (settings version 3 or older) go to "Meşgulken: Sadece göster" (0.6.20 had
moved everyone to "Yeni işleri beklet"; pick it again to have it), and their overload limit for
`compilers` goes back to the default: it was a compiler process count (12, 30…) and means nothing
as a build count.

With **"Ajanlara fren yap"** (Settings › Resources, on by default), while overloaded (new work
waits, plus the calming rules: the one queued message per episode above and the owner's
notification):

- `claudedeck new` answers `429 overloaded` (exit 4, checked before the rate limit, so it costs no
  start); `new --queue` queues instead (reason `overloaded`). The queue drains again as soon as the
  Mac is no longer overloaded.
- `claudedeck sim acquire` answers `429 overloaded`. It also answers `429 too_many_booted` whenever
  booting would exceed **"Simülatör"** (a fifth of the cores, 2–10: 4 on a 20-core Mac; booted
  simulators are counted at that moment, the user's own included), at any level.
- Build slots drop to **"Fren varken aynı anda derleme"** (1 by default).

```sh
claudedeck load [--json] [--detail]
# level: overloaded (calming down: new sessions and simulators wait, 1 build slot, agents asked once to put heavy work off)
# load: 120.4 on 20 cores (6.02 per core), 5 min 98.1
# memory: 92% used, pressure warning, swap 6144 MB
# simulators: 11 booted (sim acquire allows 4)
# builds: 9 now, 8 steady (median of the last 3 samples), 120 compiler processes
# sessions: 37 Claude sessions (5/8 agent-started), 3400 processes
# build slots: 1/1 used, 2 waiting (3 when not overloaded)
#   b_1a2b3c4d  iOS build bot  12m  xcodebuild -scheme App build
# overloaded when:
#   ok   memory pressure >= critical (now warning)
#   ok   swap +2.0 GB in 5 min under pressure (now +0.4)
#   off  swap > 64.0 GB (now 6.0)
#   FIRE builds > 7 (now 8)
#   ok   load > 10.0 x cores for 3.0 min (now 6.02)
#   FIRE processes > 3000 (now 3400)
# --detail adds:
# top sessions (CPU, memory, processes):
#     85.0%    2140 MB    14 procs  Wakeroo / backend  [agent]  (node 40%, claude 30%)
# top projects:
#    120.0%    4100 MB    31 procs  Wakeroo
claudedeck heavy [--wait SECONDS] [--label TEXT] -- COMMAND...
claudedeck slot acquire build [--wait SECONDS] [--label TEXT]     # prints b_…
claudedeck slot release build [SLOT_ID]
```

- **Build slots** are a global semaphore: **"Aynı anda derleme"** (a sixth of the cores, 1–8: 3
  on a 20-core Mac; half, rounded up, while busy holds new work, if set (2 of 3); 1 while overloaded, by its own setting). `slot acquire --wait` waits in line,
  first come first served: the command asks again every 25 s with the same ticket and keeps its
  place; a ticket not seen for 45 s gives it up. No slot in time: `429 no_slot`, exit 124.
- `heavy` waits for a slot (default up to 3600 s), runs the command, releases the slot (also on
  Ctrl+C, SIGTERM or SIGHUP) and exits with the command's code. ClaudeDeck not answering, the
  command-line tool off, or no session environment: it runs the command without a slot (a line on
  stderr), so wrapping is always safe. No slot within `--wait`: exit 124, the command doesn't run.
- Slots go back with `slot release`, when the holding session (or terminal) ends or is closed,
  and after the longest hold (Settings, 60 minutes). They live in memory: a restart of the app
  frees them. Terminals a session opened (`claudedeck open`) may take slots too (scope `slots`).
- `claudedeck status ID` lists the slots a session holds; `load --json` has `level`,
  `throttled` (something is held back now), `holds_starts`, `throttle`, `busy_action`
  (`nothing` / `hold_starts`), `load1`, `load5`, `cores`, `load_per_core`, `memory_pressure`,
  `memory_used_percent`, `swap_used_mb`, `simulators`, `max_simulators`, `builds` (running now),
  `max_builds` (the `compilers` trigger's limit), `compiler_processes`, `compilers` and `max_compilers`
  (the same as `builds` and `max_builds` after 0.6.24; they counted compiler processes before), `processes`, `sessions`, `build_slots` (handed out now), `slots_available`, `slots_waiting`, `slots`
  (`id`, `session`, `session_name`, `label`, `since`), `sampled_at`, `contributors`, `triggers`
  (each `trigger`, `enabled`, `threshold`, `current`, `unit`, `firing`, and `minutes` /
  `above_for` where they apply), `fired` (the trigger names firing now), `limits` (`build_slots`,
  `build_slots_overloaded`, `max_simulators`, `max_started_sessions`, `running_started_sessions`),
  `top` (per session: `kind`, `session`, `name`, `project`, `cpu_percent` with 100 = one core,
  `memory_mb`, `processes`, `agent`, `top_processes`) and `top_projects` (the same summed per
  project). `top` comes from one look at every process (libproc), measured on the spot (about a
  second) unless the load tab measured it moments ago; a session's figures include all its child
  processes (MCP servers, node, browsers it started, shells, builds).
- On screen: a row in the sidebar footer while busy or overloaded (or always, by a setting) and a
  "Mac Load" card on the Dashboard; both open the **"Mac Yükü"** tab: per project and session CPU
  and memory (each session with its child processes, heaviest first, with Show and, for sessions
  agents started, Close), booted simulators (holder: a ClaudeDeck hold or "kullanıcı", uptime,
  memory; Shut Down, with confirmation, only for ClaudeDeck-held ones), running builds and build
  slot holders, agent sessions idle for 15 minutes with "Boşta olanları kapat" (agent-started
  sessions only, never the owner's), the last hour as charts (load per core, memory, swap,
  simulators, builds, compiler processes) and the ten heaviest processes outside ClaudeDeck. Processes are only
  measured while that tab is on screen (every 3 s), while a phone is connected, or on `load
  --detail`/`--json`; the 12-second background sample stays a few sysctls.
- Phone: the dashboard's load card (snapshot field `load`, hosts with the `load` feature); with
  `loadDetail`, `load.top` (heaviest sessions), `load.booted_simulators` and `load.fired` add an
  optional "What is using the Mac" list. Older phones ignore the new fields. `load.builds` (and
  `history[].builds`) are builds now (compiler processes from Macs up to 0.6.24); the optional
  `load.max_builds` (the limit) and `load.compiler_processes` (set with `running_builds`, while
  measured) come with them.
- Testing: in demo mode with `CLAUDEDECK_SNAPSHOT_DIR`, a file `load.inject` containing
  `overloaded`, `busy`, `ok`, a JSON sample, or `real` replaces the measured numbers; an empty
  file `load.tab` opens the "Mac Yükü" tab.

The session helper under load: if it holds its lock but doesn't answer (at launch, or after a
dropped connection, e.g. "client N fell behind"), ClaudeDeck keeps its sessions held, shows
"Connecting to the session helper…", and retries with backoff (2 s up to 30 s apart, longer
handshakes each time) until it answers, then attaches them; a helper that is gone releases them
to the usual path. A helper that answers the handshake but not the session list in 15 s counts as
unresponsive, never as "no sessions". A session that may still run there is never started twice.

### Simulators (`claudedeck sim …`)

```sh
claudedeck sim acquire [--device "iPhone 17 Pro"] [--duo] [--keep|--keep-cat CATS] [--full-slim|--plain]
                       [--stock] [--keep-state] [--project P] [--json]
claudedeck sim release [UDID] [--unslim] [--json]
claudedeck sim list [--json]
claudedeck sim prune [--dry-run] [--older-than 3d] [--json]
```

They need **Sessions may reserve simulators** (Settings › Agents › Command-line tool; off by
default, exit 4 `setting_off`). A session gets simulators of its own, so parallel agents never
drive the same device (`xcodebuild -destination id=UDID`, `simctl … UDID`; never `booted`).

- **acquire:** one device of `--device`'s type (a `simctl list devicetypes` name, any case, or its
  identifier; default **iPhone 17 Pro**); `--duo` alone is just an **iPhone Duo**;
  `--device X --duo` is that device plus an iPhone Duo. For each one it reuses a free, shut-down
  simulator **ClaudeDeck created earlier** of that type, else creates one named
  `ClaudeDeck · <type> · <n>` on the newest installed runtime that runs that type (the iPhone Duo
  has its own runtime build, `iOS-27-2-iPhone19-4`), then boots it and waits until it's booted
  (`simctl bootstatus -b`). Prints `UDID  NAME` per device (`--json`: `udid`, `name`, `runtime`,
  `state`, `new`). It can take a minute or two. The user's own simulators (and ones other tools
  made) are never booted, handed out, shut down or erased. One acquire runs at a time, and a
  device is held before it boots, so two sessions never get the same one. At most 4 per session
  (`429 too_many_simulators`). If a device can't be created or booted, what the call got is
  released again (`500 simctl_failed`, exit 1).
- **release:** one device the caller holds (another session's: `403 not_yours`; not held: `404
  not_held`), or without `UDID` all of them. Holds also end when the session ends (not on a
  restart) or is closed; a session closed while ClaudeDeck wasn't running loses its holds at the
  next launch. With **Shut down simulators ClaudeDeck created when they're released** (on by
  default) released devices are shut down; they stay in ClaudeDeck's pool for the next acquire.
- **Holder's name:** while held, a device is renamed `ClaudeDeck · <project> · <type> · <n>` (the
  caller's project, `simctl rename`) so Simulator.app and Activity Monitor show whose it is; on
  release it gets its plain pool name back. Pool matching goes by UDID (the holds file), never by
  the shown name.
- **simslim (slim by default):** with [simslim](https://github.com/MobAI-App/simslim) installed
  (`brew install mobai-app/tap/simslim`) and **Settings › Simulators › Ajanların simülatörlerini
  hafiflet (simslim)** on (the default), acquire runs `simslim on <udid> --except <categories>`
  before handing a device out. simslim disables the background launchd services a simulator
  doesn't need; a slim iPhone uses roughly a quarter of the memory (measured on iOS 27.2: 6.9 GB
  with `store,icloud,widgets,siri` kept, 2.6 GB with none kept).
  - **Categories kept:** `store` (StoreKit sandbox, push) and `icloud` (Keychain, which the
    device-id login needs) by default. **Apps with widgets/Live Activities or App Intents must list
    them in `simslim.json`** at the repo root, e.g.
    `{"name":"wakeroo","except":["store","icloud","widgets","siri","family"]}` (`family` for
    Screen Time; an optional `"keep"` lists single launchd labels). The file is read from the
    caller's project folder, or `--project P`'s. Unknown categories are dropped and invalid JSON
    falls back to the default, both with a warning on stderr. `--keep family,health` (alias
    `--keep-cat`) adds categories for this acquire; `--full-slim` (alias `--plain`) keeps none,
    for pure screen and pixel checks; `--stock` skips simslim. `--stock` wins over `--full-slim`,
    which wins over `--keep` and the profile.
  - **Boot:** a shut-down device gets simslim's slim boot (simslim boots it). A booted device
    that `simslim verify` finds already slim with this profile only gets `simslim on --no-reboot`.
    Otherwise it's rebooted slim: stopping services without a reboot leaves most of the memory
    in use. `--keep-state` uses `--no-reboot` instead, for a device whose running state matters.
  - **Fallback:** if simslim is missing or fails (timeout 5 min), the device boots stock as before,
    stderr gets a warning and `--json` says `"slim":"unavailable"`; simslim never fails the acquire.
    `--json` adds `slim` (`on`, `off`, `unavailable`), `slim_profile` (`default`, the simslim.json's
    `name`, `full`) and `memory_bytes` (`simslim measure`). Every simslim command is in the
    activity log.
  - **Release:** the overrides stay on the device (harmless; the next acquire of it is fast, and
    the pool stays slim). `sim release --unslim` runs `simslim off` (with `--preserve-boot-state`
    when the device is shut down on release).
  - Only devices ClaudeDeck holds are slimmed or restored; the user's simulators never are.
  - `simslim watch` isn't used: it has no per-device filter and would slim every simulator on
    the Mac, the user's and other tools' too.
  - ClaudeDeck pool simulators ("ClaudeDeck · …") left booted with nobody holding them, and no
  session process using them, are shut down after 10 minutes (Settings › Agents; 0 keeps them
  running). The owner's own simulators are never touched.
- With slimming on and simslim installed the default cap on booted simulators (Settings ›
    Resources) is half again as high (4 → 6 on a 20-core Mac); a cap the owner set stays.
- **prune (the pool stays small):** for deleting, ClaudeDeck's pool is the devices named
  `ClaudeDeck · …` (a held one's `ClaudeDeck · <project> · …` too); a device ClaudeDeck created but
  someone renamed away from that prefix is never deleted. Ages are tracked by UDID
  (simulator-holds.json). A pool device is deleted (`simctl delete`) when it
  is shut down, held by nobody, and either unused for **N days** (Settings › Resources ›
  **Kullanılmayan havuz simülatörlerini sil: N gün sonra**, default **3**, `0` = never), or one of
  more than **cap + 2** pool devices of its device type (cap = the booted-simulator limit in
  Settings › Resources; booted and held devices count toward it), least recently used first.
  "Last used" is the later of the release time ClaudeDeck records per UDID and simctl's
  `lastUsedAt` (last boot); a pool device with neither starts aging when prune first sees it.
  **Never deleted:** booted or held devices, and anything outside the pool (the user's own, other
  tools', and sessions' `<Project> · <purpose>` devices). It runs a minute after launch and then
  once a day (silent unless it deleted something; each deletion is in the activity log), and on
  `claudedeck sim prune`, which prints what it deleted (`--dry-run`: what it would delete,
  nothing changes) with the reason (`unused`, `over_cap`), days unused, runtime and name.
  `--older-than 3d|12h|90m` replaces the setting's age for that run (positive only, else `400
  bad_age`); with the setting at 0 and no `--older-than` only the per-type bound applies.
  `--json`: `dry_run`, `older_than_seconds`, `max_per_type`, `items` (`udid`, `name`, `runtime`,
  `reason`, `last_used`, `data_bytes`, `deleted`, `error`). It shares the acquire queue, so it never
  deletes a device an acquire is handing out. Needs the same setting as acquire.
- **Owner only (Simulators tab › Clean Up…; no CLI route):** "Kullanılamayan simülatörleri
  temizle" runs `simctl delete unavailable` (devices whose runtime was removed) after showing the
  count; the list of simulators outside the pool (runtime, last boot, data size, and the project
  for a session's `<Project> · <purpose>` device) deletes the checked ones after a confirmation.
  Booted devices can't be selected.
- **list:** the held devices (state, holder, whether ClaudeDeck created them, simslim's
  `slim 109/173` daemons-disabled count and memory from `simslim list --json`) and ClaudeDeck's free ones.
- Holds are kept in Application Support/ClaudeDeck/simulator-holds.json. Every acquire and release
  is in the activity log. The Simulators tab shows the holder (a lock with the session's name),
  as does the phone's simulator list. The Simulators tab and the load tab's booted-simulator list
  show each device's memory and its simslim state (`simslim list --json`, read every 15 s only
  while one of them, or the phone, is looking).

### Usage per project

```sh
claudedeck usage [--project ID|NAME|PATH] [--json]
```

The plan's meter (Claude Code's `/usage`) only says how full the 5-hour and weekly windows are.
ClaudeDeck splits that by project from the transcripts: every assistant reply's `message.usage`
(input, output, cache writes and reads; sub-agents included; a reply Claude Code writes as several
lines counted once, also across files) in the transcripts of each project's folders under
`~/.claude/projects` (the project's folder and those below it, such as worktrees) and of the deck's
sessions. Each reply's cost is estimated at API prices for its model (Opus 5.5 $4/$20 per million
input/output tokens, Opus 5 and 4.5+ $5/$25, Sonnet 5 $2/$10, other Sonnets $3/$15, Haiku 4.5 $1/$5,
Fable/Mythos $10/$50, unknown models as Opus 5; cache writes 1.25× input for 5 minutes, 2× for
an hour, reads 0.1×). A project's **share** is its part of that cost in the window (the 5-hour
window from its reset minus 5 hours, the week from its reset minus 7 days), and its **percent** is
that share of the window's percent. It's an estimate: sessions outside the deck's projects, and
other devices, aren't in the transcripts it reads.

The Dashboard's **Usage by project** card shows it (5 hours / Week), and so does the phone's
dashboard (`RemoteDashboard.projects`, at most 8; Macs without it send nothing and older phones
ignore it). Transcripts are read incrementally, only while the Dashboard is on screen, a phone is
connected or the command asks, at most once a minute (30 s for the command). `--json` answers
`{five_hour_percent, five_hour_resets_at, week_percent, week_resets_at, projects: [{project_id,
name, five_hour: {input, output, cache_write, cache_read, cost_micros, messages}, week: {…},
five_hour_share, week_share, five_hour_percent, week_percent}]}`.

### Stall watch

Settings › Agents › Command-line tool › **Watch sessions other sessions started for stalls** (off
by default). Only Claude sessions started with `claudedeck new` are watched. A session is stalled
when:

- it's **working** and nothing shows progress for **N minutes** (default 15; 3–240): progress is a
  hook event or a line appended to its transcript. A long build or test run that prints nothing
  to Claude's transcript looks the same, so pick enough minutes; or
- its tool calls fail with **the same error 3 times in a row** (digits folded, so "line 12" and
  "line 13" match; any success in between starts over), or Claude Code records the same API error
  (can be turned off).

Checked every 30 s (an error loop right away). The action (**When a session stalls**):

| Action | Does |
|---|---|
| Notify only (default) | A notification |
| Nudge it | Types the **nudge message** (default "Continue", "Devam et" in Turkish) into the session, and notifies; a permission or question on screen: notification only |
| Restart it, then nudge | Restarts it into the same conversation (Restart Session, no dialog; it keeps its simulators), types the nudge once Claude is up, and notifies; a permission or question on screen: notification only |

- After an action the watch starts over: the next one comes N minutes later at the earliest.
- **At most 3 nudges and restarts per session an hour**; after that it only notifies (and logs
  that the limit was reached).
- **Leave a note beside the session that started it** (on by default): the starting session
  gets a note for the user with what happened (a note, not typed into Claude).
- Every stall and action is in the activity log ("stall watch · NAME: no progress since 14:02 →
  nudged with “Continue” (1/3 this hour)").
- `claudedeck status ID` shows `stall`: `watching`, `stalled` (`no_progress` / `error_loop` /
  null), `last_progress_at`, `minutes_without_progress`, `repeated_errors`, `last_action`,
  `last_action_at`, `interventions_last_hour` (null for sessions that aren't watched).

### Closing sessions

`close` and `remove` need **Settings › Agents › Sessions may close sessions they started** (off by
default; else `403 close_off`, exit 4). A session may close or remove only itself, the
sessions it started and the terminals it opened with `claudedeck open`, directly or through
sessions they started (`startedBy` / `openedBy` all the way up); never one the owner started
(`403 not_yours`, exit 4).

- **close ID|self:** ends it like End Session: an idle Claude gets `/exit` (up to 15 s), a
  terminal's process is ended, and its pane closes. Claude working: `409 busy` (exit 1); waiting
  on the owner: `409 blocked` (exit 3); still there after `/exit`: `409 still_running` (exit
  124). `--force` ends the process in each of those cases. `close self` answers at once
  (`closing: after this turn`, `"pending":true`) and ends once the current turn is over (`--force`:
  right away). The close is in the Activity Log; the session that started the closed one is told
  only with **Tell the starter when a session it started is closed** on (off by default): a
  one-line message in its queue, typed once it is idle. Never an owner note.
- **Removing after the close:** with **Closed sessions are removed from the list too** (under the
  close setting; **on** by default) every close by a session also removes the closed session from
  the deck, the way the owner's **End and Remove** does; `--keep` overrides it for one call and
  `--remove` removes even when the setting is off (both together: usage error, exit 2). Prints
  `closed and removed` (`--json`: `"removed":true`). `close self --remove` removes the session
  after the deferred exit.
- **remove ID:** removes a session that has already stopped (ended, or never started) from the
  deck. A running one is `409 still_running` (exit 1): use `close ID --remove`. `remove self`
  is always running, so it's refused the same way; use `close self --remove`.
- **What removing deletes:** only the deck entry (the sidebar row, its pane and what the app keeps
  for it in memory; its simulators are released and its `claudedeck` token stops working). The
  Claude transcript (`.jsonl` under `~/.claude/projects`), the project folder and any git
  work tree are kept: the owner can still reopen the conversation from the project's **Resume
  Previous Conversation…** menu. Sessions the removed one had started now count as started by
  its own starter, so that one can still close them.
- Every close and removal is in the agent Activity Log. The starter gets a queued message about it
  only with the setting above on ("X closed and removed Y, a session this one started").
- **Agents:** remove the sessions you no longer need once their work is merged and handed off
  (`close ID`, which removes by default; `remove ID` for ones that already stopped), and close
  yourself with `close self` when you are done. Idle leftover sessions crowd the owner's sidebar.
  Stop idle sessions you may need again with `close ID --keep` (or `close self --keep` while you
  wait for the owner's decision or other sessions) and bring them back with `resume`.
- **Who stopped it** is kept with the session (`stoppedBy`: `agent` after a session's `close`,
  `owner` after End Session, `/exit` typed in its pane or the process ending by itself; cleared
  when it runs again). Only `agent` stops resume automatically (below).

### Resuming sessions

`claudedeck resume ID [--prompt TEXT|-] [--queue] [--json]` restarts a stopped Claude session
with its conversation (`claude --resume <its Claude session id>`, the same start path as the
owner's Resume) and the **same ClaudeDeck id**, so `send`, `wait`, `capture` and answers to its
`decide` questions keep reaching it. It needs **Sessions may add projects and start Claude
sessions** (the `start` scope; `403 setting_off`, exit 4).

- **Whose:** the sessions `close` may end: ones the caller started, directly or through sessions
  they started (`startedBy` all the way up); never the owner's (`403 not_yours`). The caller itself
  is running (`409 running`). A plain terminal is `400 not_claude` (`restart` is for those).
- **Removed ones:** a Claude session a session removed from the list (`close --remove`, `remove`,
  or `close` with **Closed sessions are removed from the list too**) leaves a small record in
  deck.json (`removedSessions`: id, project, name, Claude session id and transcript path, working
  folder / worktree, `startedBy`, launch options, account, `stoppedBy`, `removedAt`), kept for
  **30 days** (at most 200, pruned on launch and on each removal). `resume ID` puts it back in the
  list and resumes it while its project is still in the deck and `claude --resume` can find its
  transcript (and its worktree folder still exists); otherwise `409 not_resumable` (exit 1).
  Sessions the owner removes by hand leave no record. Sessions the removed one had started were
  handed to its own starter on removal and stay there after it comes back.
- **The cap:** it counts like `new`: the Mac's load (`429 overloaded` / `busy`), the running cap
  (`429 too_many_running`) and the caller's rate limit (`429 too_many_starts`). With `--queue` it
  waits in the start queue instead (`queue list` shows `kind: resume`; prints the queue id;
  `wait q_…` follows it). A second `resume --queue` while one waits answers the same queue id.
- **`--prompt`** is its first message: put first in its prompt queue and typed at its first "your
  turn" (messages already queued follow, one per turn). A session cut off mid-turn doesn't also get
  the "continue" message. Prints `resumed` (`resumed (restored to the list)` for a removed one;
  `--json`: `{"resumed":true,"id":…,"name":…,"restored":false}`).
- Every resume (and refusal) is in the agent Activity Log.

**Automatic resume** (**Settings › Agents › Resume a stopped session when a message or a decision
answer arrives for it**, on by default): a stopped Claude session whose `stoppedBy` is `agent`
(never one the owner stopped) is resumed when

- `claudedeck send ID TEXT` (with Return) comes from a session that may resume it (the rule
  above, with the `start` scope and its setting): `delivered: resumed`, or `resume_queued` with a
  `queue_id` when the cap, the rate limit or the Mac's load says wait. A removed one (by its id) is
  restored first. When it isn't eligible, `send` is `409 not_running` as before.
- the owner answers (or changes the answer to, or dismisses) its `claudedeck decide` question:
  `delivery` `resumed` or `resume_queued` instead of `queued`. When it isn't eligible the answer
  stays in its queue as before (`queued`, or `no_session` when it's gone).

The text becomes its first message (first in its queue), so it waits with the session whatever
the start queue does; an automatic resume isn't held up by its sender closing, but it fails
(`not_agent_closed`, kept in the queue) if the owner started and stopped the session meanwhile.
With the start queue full, the text just waits in the session's queue (`delivered: queued`).

### Restarting terminals

`claudedeck restart ID [--json]` is the owner's **Restart Terminal** from a session: the old
process in that same pane is stopped (`stopForRestart`: SIGTERM, SIGKILL after 5 s) and the
terminal's startup command runs again (`launch(resume: false)`); a stopped terminal is just
started. It never creates a terminal. Answer: `restarted` or `started` (`--json`:
`{"restarted":true,"id":…,"running":true|false}`, `running` = an old process was stopped).

- **Its own terminals** (opened by it with `claudedeck open`, or by sessions it started): always.
- **Command terminals of its own project:** plain terminals with a startup command in the
  caller's project (e.g. "ServerPlan · cd servermanager; make run") only with **Settings ›
  Agents › Sessions may restart command terminals in their own project** (off by default; else
  `403 restart_off`, exit 4). The same setting lets the session `send` (with `--enter`) into
  those terminals.
- **Never** other projects, plain terminals without a startup command, terminals another session
  opened outside those rules, or Claude sessions it didn't start (`403 not_yours`). A Claude
  session it started restarts like the owner's Restart Session (resumed, no dialog; a busy one is
  `409 busy`) and needs **Sessions may close sessions they started** (`403 close_off`). Itself:
  `400 cannot_restart_self`.
- `409 read_only` when the terminal runs in another app's session helper. Every restart (and
  every send into such a project terminal) is in the agent Activity Log.

### Compacting

`claudedeck compact [ID|self] [--json]` types `/compact` into a Claude session the way the owner
would (Ctrl+C first clears a draft in its prompt). Without an ID it compacts the caller itself.

- **Itself:** when its context runs low, a session updates docs/HANDOFF.md and then runs
  `claudedeck compact`. The answer comes at once (`compacting after this turn`, `--json`:
  `{"compacting":true,"id":…,"pending":true}`); `/compact` is typed once a hook says the current
  turn is over (the same deferred mechanism as `close self`).
- **A Claude session it started** (directly or through sessions it started: the `close` chain,
  `mayClose`): idle (or at its usage limit) → typed now (`compacting`, `"pending":false`);
  working → typed once its turn is over (`compacting after its turn`, `"pending":true`); waiting
  on a permission or a question → `409 blocked` (exit 3). `claudedeck wait ID` then waits for
  the compaction to finish.
- Only Claude sessions (`400 not_claude` for terminals); never the owner's sessions or ones
  another session started (`403 not_yours`). `409 not_running` / `read_only` /
  `switching_account`. A second request while one is pending answers the same without queuing
  another.
- No setting beyond the command-line tool itself (scope `compact`): compacting loses nothing
  the transcript doesn't keep. Every request, every typed `/compact` and every give-up (the
  session stopped, or the turn didn't end within 30 minutes) is in the agent Activity Log.

### Remote Control

Claude Code's Remote Control lets claude.ai/code and the Claude app drive a running session.
ClaudeDeck shows where it is on (an orange antenna in the sidebar and on the phone) and turns it
off on the owner's word only.

- **Where it's on:** Claude Code keeps `<config dir>/sessions/<pid>.json` for every
  interactive session (`~/.claude`, or an account's `CLAUDE_CONFIG_DIR`); `bridgeSessionId` is
  set while Remote Control is connected and `null` once it isn't. ClaudeDeck reads these every
  4 seconds and matches them to its sessions by Claude session id (a leftover file of a process
  that ended doesn't count).
- **Turning it off:** typed while connected, `/remote-control` opens a dialog ("Disconnect this
  session", "Show QR code", "Continue", focus on "Continue"). Once the session's turn is over
  (and after a resume's `/compact` or continue message), ClaudeDeck clears the prompt (Ctrl+C),
  types `/remote-control` and Enter, and only when that dialog is on screen presses Up, Up,
  Enter; otherwise Esc, and the attempt counts as failed. The registry then has to say it's off
  within 10 seconds. Requested, done and failed offs are all in the agent Activity Log.
- **Who:** the owner, from File › "Turn Off Remote Control (All Sessions)", a session's menu, or
  the phone (hosts with `Feature.remoteControl`: `RemoteSession.remoteControl`,
  `RemoteSessionAction.remoteControlOff`). A session asks with
  `claudedeck remote-control off ID|self|--all`: that's an approval card for the owner (scope
  `remoteControl`, kind `other`; a phone may approve it), answered `202 pending approval a_…`
  (exit 75; the command follows it unless `--no-wait`), and nothing is typed before the yes.
  Refused: `403 owner_refused`; unanswered: `403 approval_expired`. A target that has it off
  already answers `200 already off` (`{"remoteControl":"off","sessions":[],"pending":false}`)
  without asking. Approved: `{"remoteControl":"off","sessions":[…],"pending":true}`. Not kept
  across a relaunch of ClaudeDeck (withdrawn, like the phone's container actions).
- **Why resumed sessions come back with it on:** `claude --resume <id>` turns Remote Control on
  again whenever the conversation's last `bridge-session` record (in its transcript) has an id,
  whatever `remoteControlAtStartup` says; that setting only covers fresh sessions, and there is
  no flag or environment variable to start with it off. A disconnect writes an empty record, so
  later resumes stay off. Settings › Sessions › "Keep Remote Control off" (on by default) turns
  it off once in a session ClaudeDeck resumed whose Remote Control came back within 90 seconds;
  turned on later by hand, it stays on until the next resume.

### Claude accounts and usage limits

The owner may add Claude accounts besides the default one in **Settings › Accounts** (none by
default; with none nothing below changes). Each account is a Claude Code config folder
(`CLAUDE_CONFIG_DIR`, under Application Support/ClaudeDeck/accounts/NAME) that the owner logs in
to with `claude auth login` in a ClaudeDeck terminal; Claude Code keeps that login in its own
Keychain item for the folder. ClaudeDeck never handles a password or a token, and nothing about
the login is put in a session's environment or transcript (only `CLAUDE_CONFIG_DIR`). Account
folders link the owner's `~/.claude` setup (settings and hooks, CLAUDE.md, skills, agents,
commands, plugins) and its `projects` folder, so every account writes the same transcripts; the
owner's MCP servers, onboarding answers and each folder's trust are copied into the account's
`.claude.json` before a session starts there.

- **Which account a session runs on:** a project pinned to an account (its menu › Account) runs
  every session there; otherwise `new --account NAME|auto`, else the setting **New sessions start
  on** (an account, or Automatic: the first by priority with room). A start that nobody chose an
  account for skips one that is at its limit or near it (**Near the limit at**, 95 % of the
  5-hour or weekly window by default) while another has room; so does the `--queue` drain.
- **When a session hits the usage limit** (detected from its transcript, as for "continue when the
  limit resets"), with **Switch to another account**: ClaudeDeck waits for the old `claude` to exit
  (never resumes one that may still run), then starts `claude --resume <same id>` on the first
  account by priority that is logged in, not at its limit and not near it, in the same pane, with
  the same ClaudeDeck session id, name, folder or worktree, options (`--permission-mode`,
  `--allowedTools`, `--model`, `--effort`), Pencil MCP and `startedBy`. Its `claudedeck` token
  stays valid, so `send`, `wait`, decisions and their delivery keep working. If it was in the
  middle of something it gets:
  `[ClaudeDeck] Account switched after a usage limit. Continue exactly where you left off: re-read docs/AGENDA.md (and HANDOFF.md if present), then resume the current task.`
  An idle session is resumed silently. When every account is at its limit, the session waits:
  it moves as soon as another account has room (checked every 30 seconds and after every usage
  reading), or gets the usual continue message when its own limit resets (5-hour or weekly, on
  any account). Either message is watched for: if it doesn't show up in the transcript within
  90 seconds while the session sits idle, it is typed again (three tries, then a notification).
  Every move and every continue is in the activity log with its reason; a move after a limit
  also gets a notification (and a push to the phone when remote mode is on). **Notify me**
  instead offers the move in a notification with a **Switch Account** button. Pinned sessions
  (their menu › Account › Keep on This Account) and sessions in a pinned project never move.
- **Idle sessions on a used-up account** move silently to one with room before they are next
  used: on their own (every 30 seconds) when they sit at their prompt, and in any case the moment
  a message is about to go in (a queued prompt, `claudedeck send`, a decision's answer, the
  phone): the message waits in the session's queue and goes in once it is back. Never a session
  in the middle of a turn, with a prompt or question on screen, or pinned. A session with
  background tasks still running (a `run_in_background` shell or agent with no
  `<task-notification>` yet) isn't moved on its own, since the move would end them; it moves
  when it is next used (its next request would hit the limit anyway).
- **No flapping:** a session only ever moves away from an account that is used up, never from
  one that still has room; an idle session moved ahead of time, or a new one leaving a near-limit
  account, only goes to an account 5 points below **Near the limit at** (a session stopped on the
  limit, or one a message is about to go into, takes any account below it); and ClaudeDeck moves
  a session by itself at most once every 10 minutes.
  An account whose usage can't be read is never a target for an idle session; a stopped one
  prefers accounts whose usage is known.
- **With `close` and the stall watch:** a session at its limit (`limit_reached`) or being moved
  (`switching_account`) never counts as stalled (no nudge, no restart; the watch starts over once
  it works again). `close` on a session being moved is refused (`409 switching_account`; try
  again); `close self` waits until the move is done.
- **What a session should do:** nothing special. Keep durable state in files (`docs/AGENDA.md`
  for what's done and next, `HANDOFF.md` for anything mid-flight) so a resumed session can pick
  up from them.
- **Good to know:** moving a session back to the default account copies its folder's trust answer
  into the real `~/.claude.json` (the way `ClaudeTrust` adds it, only that key) when the folder
  was trusted on the other account. If Claude Code ever replaces a linked file in an account folder
  with its own copy (e.g. `settings.json`), that account stops following later changes to the
  shared one; ClaudeDeck logs it ("not linked (in the way)") and leaves the file alone. Which
  account is used up, and until when, comes from sessions' limit messages and from the usage API
  (a full 5-hour or weekly window); ClaudeDeck keeps it in `account-limits.json` (next to
  `deck.json`) across relaunches, and keeps an account's last usage reading while it can't be
  read (an expired token on an account nothing runs on), so such an account never looks free.
  A later reading with every window clearly below full (under 90 %) drops the record. A limit a
  session hit while ClaudeDeck wasn't attached (a relaunch with sessions kept running) is picked
  up from the transcript when ClaudeDeck attaches. In demo mode, `CLAUDEDECK_DEMO_USAGE` pins
  each account's usage (tools/demo.sh).

```sh
claudedeck account list [--json]
# PRIO  NAME     5H    WEEK  STATE    RESET  SESSIONS
# 1     default  100%  41%   limited  1h 12m 3
# 2     work     12%   8%    ok       -      1         current
claudedeck account current            # work
claudedeck account switch [--to NAME] # ends this session and resumes it on NAME a moment later
claudedeck new --account auto --prompt "…"
```

`account list --json`: `[{name, label, priority, active, current, logged_in, five_hour, weekly,
limited, near_limit, reset_at, sessions}]` (`active`: where new sessions start; `current`: the
caller's; percentages null when unknown). `account switch` answers first (`{from, to,
scheduled: true}`) and moves the session two seconds later; it is refused for a pinned session
(`pinned`), an account nobody is logged in on (`not_logged_in`) or one at its limit
(`account_limited`); without `--to` it picks the first account with room (`no_account` when there
is none).

### Decisions for the owner

```sh
claudedeck decide "Which database for the cache?" --options "Redis,SQLite,None" --recommend Redis \
  --context "Redis adds a container; SQLite is enough below 1k rps."   # prints d_1a2b3c4d5e
claudedeck decision get d_1a2b3c4d5e    # "pending", "answered: SQLite", "answered: SQLite (changed)" or "cancelled: REASON"
                                        # (then id, question, options, "was: OLD" per earlier answer, delivery…)
claudedeck decisions --pending          # ID, STATUS, PROJECT, QUESTION, ANSWER; newest first
claudedeck decide "Önbellek için Redis mi, SQLite mı?" --options "Redis,SQLite" --supersedes d_1a2b3c4d5e
claudedeck decision cancel d_1a2b3c4d5e --reason "artık gerekmiyor"   # prints "cancelled d_1a2b3c4d5e"
```

A session that needs the owner's call doesn't stop and wait: `decide` returns at once with the
decision's id (`d_` and 10 hex digits) and the session keeps working on what doesn't depend on it.
Only the command-line tool's setting is needed (no separate one); a terminal a session opened
can't ask.

- **Arguments:** `QUESTION` (at most 2 000 characters); `--options` separated by commas, or one
  per line when the value has line breaks (at most 10, 200 characters each; blank and repeated ones
  dropped; none: the owner answers in words); `--recommend` one of the options (any case) or its
  number (`400 bad_recommend` otherwise); `--context` the facts the owner needs (at most 8 000
  characters; `-` reads stdin); `--project` an id, name or path as for `new` (default: the
  caller's project; unknown: exit 5); `--supersedes ID` (below).
- **Turkish:** the owner reads these in Turkish. When the question and the options have no
  Turkish-only letter (çğıöşü and their capitals) and none of a few common Turkish words (ve, bir,
  mi/mı/mu/mü, için, ile, bu, ne, hangi, olsun), `decide` still asks but prints
  `decide: owner-facing text should be Turkish (soru Türkçe olmalı)` on stderr (the API sends
  `X-ClaudeDeck-Note: not_turkish`). It never refuses.
- **No duplicates:** when the same session already has a pending decision with the same question
  (case, runs of spaces and trailing punctuation ignored), `decide` creates nothing: it prints the
  waiting one's id (its JSON with `--json`), exit 0, and `decide: already pending as d_…` on
  stderr (`X-ClaudeDeck-Note: already_pending:d_…`). It doesn't count against the rate limit.
- **Cancel:** `decision cancel ID [--reason TEXT]` withdraws a pending decision (status
  `cancelled`, `cancel_reason`, `cancelled_at`; default reason "cancelled by SESSION"). Only the
  session that asked it, or one in its `startedBy` ancestry (the session that started it, and up),
  may (`403 not_yours`); an answered one is `409 already_answered`, a cancelled one `409
  already_cancelled`, an unknown one `404 unknown_decision`; exit 4 / 5. The ancestry is the
  deck's now plus the one recorded when it asked, so a parent can still cancel after the asking
  session is gone.
- **Replace:** `decide … --supersedes ID` cancels `ID` (same rule; reason `superseded by d_new`)
  and asks the new one in one step. When `ID` can't be cancelled, nothing is created and the
  refusal is the cancel's (403 / 404 / 409). If the new question is already pending from this
  session, that one's id comes back and `ID` is cancelled as superseded by it.
- **Cancelled ones** leave the pending list, the sidebar count, the phone's count and the
  phone's list at once; the Mac keeps them in a collapsed "Cancelled" (İptal edilenler) history,
  `decisions` lists them with status `cancelled`. They're never sent to phones (an older phone
  would show an unknown status as waiting).
- **The owner** sees it in **Your Decisions** (Window menu, and a tray above the sidebar's waiting
  tray with the count while any wait): question, project, the asking session, the context and the
  options with the recommended one first and marked. A click on an option only selects it ("Double-click
  to confirm"); a **double click** answers, so a stray click never does. Words of one's own go with
  the **Send** button (Return doesn't send). The phone shows the same list (remote feature
  `decisions`): a tap selects an option and a **Send "…"** button under the options confirms it. A new decision is a notification on the Mac (unless notifications are off; clicking
  opens the list) and a push to paired phones that aren't connected.
- **The answer** goes to the asking Claude session as a message through its prompt queue: typed
  at its next "your turn" (at once when it's idle), never into a permission prompt or a question,
  and kept in the queue if the session isn't running until it is. It's one line:
  `[ClaudeDeck decision d_…] The owner answered your question "…": ANSWER`. `decision get` shows
  it too (`delivery`: `queued` while it waits for the session's turn, `delivered` once typed
  into it (since 0.6.31); `terminal` when a plain terminal asked, where nothing is typed;
  `no_session` when the session is gone). A stopped (or removed) session a session closed is
  resumed for it when **Resume a stopped session when a message or a decision answer arrives for
  it** is on: `resumed`, or `resume_queued` while it waits for room (see
  [Resuming sessions](#resuming-sessions)); one the owner stopped keeps it queued.
  The first answer counts; one from the other device a moment later is ignored (Activity Log).
- **Recent answers, changeable:** under the pending ones, the last 5 answered decisions (muted:
  question, answer, when) and a collapsed **Other decisions today** with the rest of today's;
  older days aren't shown (the file keeps them). Today's cancelled ones are in their own collapsed
  list on the Mac. **Change…** on one shows its options (same double click / Send rule) and a
  field: the new answer replaces the old one (kept in `answer_history` with its time and device;
  `changed_at`), and the asking session gets one line through its queue, as answers go:
  `[ClaudeDeck decision d_…] The owner changed the answer to your question "…": NEW (was: OLD)`.
  When the session is gone the change is only stored (`delivery: no_session`). `decision get`
  then shows `answered: NEW (changed)` and a `was: OLD` line per earlier answer. The phone does
  the same with Macs that have remote feature `changeDecisionAnswer` (older phones and Macs
  ignore the extra fields and the new message).
- **Removed by the owner:** **Remove** on a card (or its context menu) on the Mac, or a swipe on
  the phone (Macs with remote feature `dismissDecision`), dismisses it without an answer: it is
  cancelled with reason `owner dismissed`, and the asking session gets one line through its queue,
  as answers go: `[ClaudeDeck decision d_…] The owner dismissed your question "…" without
  answering. …` (`delivery` as for answers).
- **Text size:** the tab's − / + in its header, or ⌘+ / ⌘- / ⌘0 while it's in front (11–24 pt,
  15 by default; kept).
- **JSON** (`--json`): `id, question, options, recommended, context, project_id, project,
  session_id, session, created_at, status` (`pending`/`answered`/`cancelled`)`, answer, answered_at,
  answered_from` (`mac`/`phone`)`, delivery, cancel_reason, cancelled_at, ancestors` (the asking
  session's starters when it asked)`, answer_history` (`[{answer, answered_at, answered_from}]`,
  earlier answers, oldest first)`, changed_at`; every key is always there.
- **Limits:** 10 per 10 minutes per session (`429 too_many`), 50 waiting at once (`429
  too_many_pending`); exit 4. Kept in Application Support/decisions.json: every pending one and
  the newest 200 answered or cancelled. Asking, answering, cancelling, dismissing, duplicates and
  refusals are in the Activity Log.

### Agenda board

A project with `docs/AGENDA.md` gets a board: **Agenda Board** in the project's menu on the Mac
(a tab), and **Agenda** on the phone (remote feature `agenda`, read-only). The file is read when
its size or modification time changes (looked at every 2 s), so agents update the board by editing
the file. Every markdown table whose header has an `id` and a `status` column is read (tables in
code blocks aren't); the other columns are found by name, in any order and case, punctuation
ignored: `track` (also lane, stream, area, epic, phase), `owner` (also agent, `owner (agent)`,
assignee), `depends-on` (also depends, deps, dependencies, blocked by), `evidence` (also proof,
links), and a title column (title, task, item, name, description, summary). Other columns are
ignored; a short row leaves the rest empty; `\|` is a pipe inside a cell. Statuses: `todo` (to do,
open, backlog…), `doing` (in progress, wip…), `review` (in review, qa…), `blocked` (on hold…),
`done` (complete, closed, ✅…); anything else is under **Other** with its text. Dependencies are
separated by commas, semicolons or spaces (`—`, `none`: none); a done one is struck through.
At most 500 rows and 500 characters per cell; files over 1 MB aren't read.

```markdown
| id | track | owner | status | depends-on | evidence |
|----|-------|-------|--------|------------|----------|
| A1 | api   | backend | done   | —          | [PR #12](https://…) |
| A2 | api   | backend | doing  | A1         |          |
| B1 | ios   | ios     | review | A1, A2     | screenshots/b1.png |
```

### Projects and Claude sessions

```sh
claudedeck projects [--json]
claudedeck project add PATH [--name NAME] [--group GROUP] [--create] [--json]
claudedeck new [--project ID|NAME|PATH] [--name NAME] [--prompt TEXT] [--worktree NAME]
               [--permission-mode MODE] [--allow RULE]... [--model MODEL] [--effort LEVEL]
               [--skill NAME] [--queue] [--json]
claudedeck preset show [PROJECT] [--json]
claudedeck preset set PROJECT [--permission-mode MODE] [--allow RULE]... [--model MODEL] [--effort LEVEL] [--json]
claudedeck preset clear PROJECT
claudedeck queue list [--json] | queue show QID [--json] | queue cancel QID
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
  way they make theirs: under their lock (`~/.claude.json.lock`, waited for up to 3 s; only
  one untouched for 30 s, left by a process that's gone, is removed), from a fresh read, inserted into the text so every other byte stays, checked (the
  result must be the old config plus that key), written to a temporary file and renamed over the
  original only if the file is unchanged since the read (inode, size, modification time),
  otherwise read and done again. Nothing is written when the file isn't a JSON object. It's in
  the Activity Log and the notification ("… and trusted its folder"); when it can't be done, the
  notification says Claude Code is asking. A folder outside those rules is left to Claude Code
  (Activity Log only; it may already be trusted). Sessions the owner starts keep asking as before. The
  demo uses its own `~/.claude.json` (in its home), never the real one, and its stand-in `claude`
  shows the question in folders that aren't trusted.
- **How the session runs** (`new`, all optional; without them `claude` starts exactly as before):
  - `--permission-mode MODE`: `claude --permission-mode MODE`. MODE is what Claude Code takes:
    `default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `manual` (2.1's name for `default`) or
    `bypassPermissions`. `bypassPermissions` also needs **Sessions may start sessions that skip
    all permission prompts** (under the setting above; off by default): off, `403 bypass_off`
    (exit 4), and a session that was started with it while it was on starts in Claude Code's
    default mode after it's turned off (logged).
  - `--allow RULE` (repeatable): `claude --allowedTools RULE…`. A rule is a tool name, with a
    pattern in parentheses if wanted: `Edit`, `"Bash(git *)"`, `WebFetch(domain:example.com)`,
    `mcp__server__tool`. One line, at most 300 characters, never starting with `-`; at most 50.
    A rule that allows every shell command (`Bash`, `Bash(*)`, `Bash(:*)`, the same for
    `PowerShell`) is as good as skipping permissions, so it needs the bypass setting too
    (`bypass_off`), and is left out when the session starts after the setting was turned off.
  - `--model MODEL`: `claude --model` (an alias like `opus` / `sonnet` or a full id; letters,
    digits and `. _ - [ ] : / @`). `--effort LEVEL`: `claude --effort` (`low`, `medium`, `high`,
    `xhigh`, `max`).
  - Each value goes to `claude` as its own argument (no shell in between), between the Pencil
    MCP option and `--name`, so `--allowedTools` (which takes several values) ends at `--name`.
    The options are kept with the session (`launchOptions` in deck.json) and passed again on
    every start, a resume or a restart included.
  - **claudedeck keeps working:** a session started with a mode or rules (from the flags or the
    preset) is also allowed `Bash(claudedeck *)` and `Bash(<the script's absolute path> *)`, so
    `send`, `wait`, `capture` and the rest still run in a mode that refuses what wasn't allowed
    (`dontAsk`) and don't stop at a prompt in the others. Messaging between sessions is
    `claudedeck send` (the rule above, unchanged): the session that started another may type into
    it; anyone else's text is a note unless **May type into Claude** is on. (Claude Code's own
    `SendMessage` is between agents inside one `claude` process and isn't affected.)
  - `--skill NAME`: the first thing typed is `/NAME` (and the prompt after it, as the skill's
    arguments), once Claude is up, as `--prompt` is. NAME is a skill (`skills/NAME/SKILL.md`, or
    a `SKILL.md` whose `name:` is NAME) or a command (`commands/NAME.md`) in `~/.claude` (and
    `$CLAUDE_CONFIG_DIR`), in the project's `.claude`, or in an installed plugin (`plugin:NAME`,
    or a plain NAME any plugin has). Not found: `404 unknown_skill`, exit 5, nothing starts.
- **Presets:** `preset set PROJECT …` keeps options for the sessions `new` starts in PROJECT
  (`self`, an id, a name or a path, as for `new`). `new` uses the preset for every option it
  isn't given: a flag replaces that one field (`--allow` the whole list), and
  `--permission-mode default` overrides a preset's mode. `set` replaces the whole preset; `clear`
  removes it; `show` prints one project's (or, without PROJECT, every one). Presets are in
  deck.json (`cliPresets`), apply only to sessions `new` starts (never to the owner's), and the
  preset in effect when the session starts counts (also for a queued one). A preset with
  `bypassPermissions` can only be set while that setting is on. Setting and clearing are in the
  Activity Log.
- **Running cap:** counts only agent-started sessions that are **working**: Claude mid-turn, or a
  terminal's program running, plus any started in the last minute (not reporting yet). One idle at
  its prompt, or waiting on a question or a permission, doesn't take a place (since 0.6.24).
- **Queue (`new --queue`):** when the start would be refused for the running cap
  (`too_many_running`) or the caller's rate limit (`too_many_starts`), it waits in a queue
  instead and the command prints the queue id (`--json`: `{"queued": true, "queue_id": "q_…",
  "position": N, "reason": "too_many_running"}`), exit 0. Every other refusal (setting off,
  unknown project or skill, `bypass_off`, a bad value) is answered at once, as without
  `--queue`. The queue is checked every 2 seconds while something waits; oldest first, each starts
  once the cap has room and its caller's rate limit allows (a caller over its limit doesn't hold
  up the others), with the same start, notification and log as `new`. It's kept in deck.json
  (`cliQueue`), so it survives a restart and drains once the app runs again. A queued start
  fails instead of starting when the setting was turned off (`setting_off`), the caller's
  session was removed (`caller_gone`) or the project is gone. At most 20 waiting per caller and
  50 in all (`429 too_many_queued`); finished entries are kept 24 hours.
  - `queue list`: every entry (who queued it, `#N` while waiting, the session once started).
  - `queue show QID`: the session id once it started (exit 0), `queued #N` (exit 0), or
    `cancelled` / `failed (reason)` (exit 1).
  - `queue cancel QID`: only the session that queued it (`403 not_yours`), only while it waits
    (`409 not_queued`).
  - `wait QID` (and `--all|--any`) waits for the start and then for the session; `send` and
    `capture` take a started queue id too (`409 queued` before).
- **Guardrails:** per calling session at most 5 `new` in 10 minutes and 10 new projects an hour;
  at most 8 sessions started this way running at once (all callers). Over a limit: `429`, exit 4
  (`new --queue` waits for room instead).
  Every action is in the agent Activity Log, and the owner gets a notification "started Y in Z"
  (what one session does within 3 s is one notification). Terminals a session opened with
  `claudedeck open` don't have these scopes (`403 not_allowed`).

### Renaming projects (coordinator projects)

```sh
claudedeck project rename PROJECT NEWNAME [--folder] [--json]
```

- **Coordinator projects.** The owner marks a project with **Coordinator project (may write
  every project's status and rename projects)** in its context menu (`"coordinator": true` on
  the project in deck.json; missing or `null` is off, and turning it off removes the key). There
  is no command for it. Only a Claude session (scope `projectRename`: not the owner's plain
  terminals, not terminals a session opened) of a coordinator project may rename projects;
  anyone else gets `403 not_coordinator` (exit 4). It doesn't need **Sessions may add projects
  and start Claude sessions**.
- **What it does:** exactly the project's **Rename…** (`AppModel.performProjectRename`, the same
  code). PROJECT is `self`, an id, a unique prefix, a name or a path. Without `--folder` only the
  display name changes. With `--folder` (**Rename the folder too**) the folder is renamed next to
  where it is (NEWNAME is the folder's new name, never a path: `/`, `.` and `..` are
  `400 bad_name`; a move to another parent folder isn't supported, as in the UI), then Claude's
  conversations of it and of folders inside it (`~/.claude/projects/<encoded path>`) move,
  `git worktree repair` runs in it, and the deck follows (the project's path, its sessions'
  working directories and transcript paths). The ServerPlan paths under it follow too (below).
- **Nothing of the project may run:** while any session or terminal of PROJECT runs (the
  caller's own included, when it renames its own project) the answer is `409 sessions_running`
  (exit 1) with `{"error","message","sessions":[{"id","name","kind"}]}`, `message` naming each
  one; nothing changes. This holds for a name-only rename too.
- **Errors:** `404 unknown_project` (exit 5), `400 ambiguous`, `400 bad_name` (exit 2),
  `409 exists` (something already has the new name), `409 missing` (the folder is gone),
  `500 rename_failed` (exit 1).
- **Answer:** `renamed: OLD → NEW`, `folder: OLD_PATH → NEW_PATH` and `serverplan: …`; `--json`:
  `{"id","name","oldName","path","oldPath","folderMoved","serverplan"}`.
- Every rename and refusal is in the Activity Log.

**ServerPlan's paths follow a moved folder** (UI, phone or CLI). ServerPlan keeps local paths:
projects' `path`, project dirs' `path` / `local_path` and static sites' `local_sync_path`. Once the
folder moved, ClaudeDeck asks ServerPlan to rewrite those that are the old folder or inside it
(whole path components: `/a/WhatsCode` never matches `/a/WhatsCode2`); ids don't change.
`POST /api/v1/agent/paths/relocate` `{"old_prefix","new_prefix","dry_run","confirm"}` (scope
`projects_write`, an admin token; offered when `/me` lists the `paths_relocate` feature): a dry run
first (a `409 conflict` stops it), then, when it would change anything, the real run with
`confirm` = the normalized old prefix. This needs no owner approval: the folder already moved and
the owner (or a coordinator session) asked for that. The answer's `serverplan.status`:
`relocated` (with `count` and `changes`), `nothing`, `not_supported` (the panel lacks the feature;
`stale` lists the paths ClaudeDeck could see under the old folder), `serverplan_off` or `failed`
(`message`). A ServerPlan problem never undoes the rename; `failed`, and `not_supported` with
stale paths, also post a notification. It's in the Activity Log.

`403 not_yours`, `404 unknown_decision`, `409 already_answered` / `already_cancelled`, `429 too_many_pending`; for `sim` `404 unknown_device` / `no_runtime` / `not_held`,
`429 too_many_simulators`, `500 simctl_failed` (with `message`); for `close` `403 close_off` / `not_yours`,
`409 busy` / `blocked` / `still_running` (exit 124) / `read_only` / `not_closed` / `switching_account`; for `remove`
`403 close_off` / `not_yours`, `409 still_running` (exit 1) / `switching_account`. The routes for agents above (`/v1/projects`,
### Project status (`claudedeck project status …`)

Each project can show a short status next to its name in the sidebar ("1.0 in review",
"Live · Nov 22", "1.0.1 waiting (PPO)", "Design", "Stopped"), so the owner sees where every
project stands. **Leads update it at each milestone**: when a phase starts or ends, a build goes
to review, a release ships, the project waits on the owner, or it stops.

```sh
claudedeck project status set PROJECT --text "…" [--summary "…" | --summary -] [--tone ok|wait|warn] [--json]
claudedeck project status get [PROJECT] [--json]     # no PROJECT: every project
claudedeck project status clear PROJECT [--json]
```

- PROJECT: `self`, an id (or a unique prefix of 4+ characters), a name or a path, as for `preset`.
- `--text`: about 24 characters show; longer text is cut with "…" in the sidebar, over 80
  characters is refused (`400 text_too_long`, exit 2). Line breaks become spaces; empty is
  `400 empty_text`.
- `--summary` (`-` reads stdin): the tooltip, a few lines, at most 600 characters
  (`400 summary_too_long`): what was done last and the next step.
- `--tone`: `ok` green, `wait` orange, `warn` red; none: the secondary color (`400 bad_tone`).
- **Who may write:** a session sets its own project's status only (`403 not_your_project`,
  exit 4). A coordinator project's sessions may set any project's: the owner turns that on in
  the project's context menu ("Coordinator project …"; `Project.coordinator` in deck.json, there is
  no command for it). Writing needs the scope `projectStatus` (Claude sessions and your own
  terminals; not terminals a session opened with `claudedeck open`). Reading needs only `list`.
- **Routes:** `GET /v1/cli/project-status` (every project), `GET /v1/cli/projects/{ref}/status`,
  `POST /v1/cli/projects/{ref}/status` (`text`, `summary`, `tone`; `clear=1` removes it). JSON:
  `{"project_id","project","text","summary","tone","updated_at","updated_by","stale","coordinator"}`
  (every key always there, null when unset; the list is an array of these for every project).
- Stored on the project in deck.json (`status`: `text`, `summary`, `tone`, `updatedAt`,
  `updatedBy` = the session's name); older files without it decode as no status. Every set,
  clear and refusal is in the Activity Log.
- **Sidebar:** small and in the tone's color next to the project's name; older than 7 days it is
  dimmed. The tooltip has the full text when cut, the summary, then "Updated: <relative date> ·
  <session>". The owner clears it from the project's context menu ("Clear Status").
- **Phone:** hosts with `RemoteSnapshot.Feature.projectStatus` send it as `RemoteProject.status`
  (optional; older phones ignore it). The remote shows the text on project rows and the summary
  at the top of the project's long-press menu.

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
| `server logs SERVER CONTAINER [--tail N] [--follow] [--grep TEXT] [--since T] [--until T] [--timestamps]` | `GET …/logs`; `--follow` the log stream, 25 s per request. `--grep`: case-insensitive text (one line, at most 200 characters with `log_query`), the panel's with `log_query` (then `--tail` counts after the filter), else on the fetched tail; with `--follow` always filtered here (the stream refuses `grep`). `--since` / `--until` (`10m`, `2h` or RFC 3339 without spaces) and `--timestamps`: only with `log_query` (else 501); `--until` not with `--follow` | |
| `server deploy PROJECT [--server S] [--force] [--wait]` | `POST /projects/:id/deploy` | confirmed automatically, logged |
| `server deploy-status ID [--wait]` | `GET /deployments/:id` (long poll with `--wait`) | |
| `server container SERVER CONTAINER start\|stop\|restart` | `POST …/containers/:name/:verb` | the owner's dialog |
| `server container SERVER CONTAINER status\|inspect` | `GET /servers/:id/containers` + `/domains` + `/projects` (+ `GET …/containers/:name` with `container_inspect`): state, health, uptime, exit code, image, ports, domains, project | |
| `server container SERVER CONTAINER env` | the container's ServerPlan project (the panel's container ↔ domain ↔ project rule), then `GET /projects/:id/env` (secrets hidden) | |
| `server container SERVER CONTAINER logs …` | the same as `server logs SERVER CONTAINER …` | |
| `server container SERVER CONTAINER stats` | `GET …/containers/:name/stats` (`container_stats`; a one-row list) | |
| `server container SERVER CONTAINER recreate\|pull\|remove` | `POST …/recreate` · `POST …/pull` · `DELETE …/containers/:name` (`container_recreate`, `image_update`, `container_remove`; scope `containers`; remove: admin token). The panel's checks come first and go straight back without asking anyone: recreate only for a ServerPlan Dockerfile project's container (`400`), `409 conflict` while that project deploys; pull not for project containers (`400` "deploy kullanin") nor compose-managed ones; remove never traefik / postgres / redis / minio (`400`). A failed recreate or pull is `502 action_failed` with docker's output (pull restores the old container) | the owner's dialog (confirm = the container) |
| `server stats SERVER` | `GET /servers/:id/health` (CPU %, memory %, disk %, load) + `GET …/containers/stats` with `container_stats` | |
| `server disk SERVER` · `prune SERVER [--images dangling\|unused\|none] [--volumes] [--no-build-cache] [--no-containers]` | `GET /servers/:id/docker/disk` · `POST /servers/:id/docker/prune` (`docker_prune`; prune: scope `containers`, admin token). The 428 summary warns about volume data and about stopped project containers needing a redeploy; a partial failure is `502 action_failed` with `reclaimed_bytes` and the output | prune: the owner's dialog (confirm = the server) |
| `server ratelimit show HOST` | `GET /ratelimit?host=` (1.5, `ratelimit`; scope `read`) → `{"zone_rules":[{"description","expression","action","ratelimit":{"characteristics","period","requests_per_period","mitigation_timeout"}}]}` | |
| `server ratelimit set HOST [--paths /init,/v1/*] [--rate 20/10s]` | `POST /ratelimit` `{"host","paths","requests","period"}` (scope `dns`) → `{"rule"}` | the owner's dialog when the zone already has a rule (confirm = the host) |
| `server ratelimit clear HOST` | `POST /ratelimit/clear` `{"host"}` (scope `dns`) → `{"cleared":true}` | always the owner's dialog (confirm = the host) |
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
| `server static add SERVER BASE` | `POST /domains/quick-static` (scope `domains`) | none (autonomous) |
| `server domain add --static SERVER SUB BASE [--target T] [--no-clean-urls]` | `POST /domains` (`type: static`) | none (autonomous) |
| `server sync DOMAIN FOLDER` | `POST /domains/:id/sync` (scope `deploy`) | none (autonomous) |
| `server env rescan PROJECT [--dry-run]` | `POST /projects/:id/env/rescan` `{"dry_run"}` (scope `projects_write`) | |
| `server paths relocate OLD_PREFIX NEW_PREFIX [--dry-run]` | `POST /paths/relocate` `{"old_prefix","new_prefix","dry_run","confirm"?}` (feature `paths_relocate`; scope `projects_write`, admin token) → `{"dry_run","old_prefix","new_prefix","changes":[{"table","id","name","field","old","new"}],"count","skipped_deleted","warnings"}`. Rewrites projects.path, project_dirs.path / local_path and domains.local_sync_path under OLD (whole path components), ids unchanged. Prefixes are checked first (absolute, not `/`, different, neither inside the other: `400 bad_prefix` / `same_prefix` / `nested_prefix`). `409 conflict` on a collision (dry runs too) or when NEW doesn't exist (real run). Without the feature: `501 not_available` | a real run: the owner's approval (the panel's 428 summary; confirm = the old prefix). `--dry-run`: none |
| `server env rm PROJECT ENV_ID` | `DELETE /projects/:id/env/:envId` `{"confirm"}` (scope `projects_write`, permission `projects.manage_env`) → `{"deleted","key","remaining_copies"}` | the owner's dialog (confirm = the key; the summary says how many copies of it remain) |
| `server sql PROJECT QUERY\|- [--local] [--write]` | `POST /projects/:id/sql` `{"query","target":"deploy"\|"local","write"?}` (scope `sql`; `--write` also `sql_write`) | `--write`: the owner's dialog (confirm = the database name) |
| `server local run PROJECT [--server S] [--port N] [--no-cache] [--wait]` | `POST /projects/:id/local-run` (scope `local`) | |
| `server local status PROJECT [--wait]` · `logs PROJECT [--tail N]` · `stop PROJECT` | `GET …/local-status` · `GET …/local-logs?tail=N` · `POST …/local-stop` | |
| `server local-env get\|set\|unset PROJECT …` | `GET`/`PUT /projects/:id/local-env` `{"vars"}` · `DELETE …/local-env/:key` (set, unset: scope `local`) | |
| `server db clone-for-local PROJECT [--server S] [--database DB] [--target NAME] [--wait]` | `POST /servers/:id/pg/databases/:name/clone-for-local` `{"project_id","target_name"?}` (scope `databases`) | |
| `server db clone-status JOB [--wait]` | `GET /pg/clone-jobs/:jobId` | |
| `server git branches\|pull\|push PROJECT` · `git switch PROJECT BRANCH` | `GET …/branches` · `POST …/git-pull` · `…/git-push` · `…/switch-branch` `{"branch"}` (scope `projects_write`) | push, switch: the owner's dialog (confirm = the project) |
| `server refresh PROJECT` · `build PROJECT [--no-cache]` | `POST …/refresh` (`projects_write`) · `POST …/build` `{"no_cache"}` (`deploy`) | |
| `server pull-deploy PROJECT [--server S] [--force] [--wait]` | `POST …/pull-deploy` `{"server_id","force_rebuild"?}` (scope `deploy`) | none (no confirmation on the panel) |
| `server diagnose PROJECT` · `diagnose fix PROJECT ACTION` | `POST …/diagnose` · `POST …/diagnose/fix` `{"action"}` (admin token) | fix: the owner's dialog |
| `server deploy-cancel DEPLOYMENT` | `POST /deployments/:id/cancel` (scope `deploy`) | the owner's dialog (confirm = the project) |
| `server domain set DOMAIN [--server S] [--port N] [--target T] [--project P] [--[no-]websocket] [--[no-]clean-urls] [--[no-]ssl]` | `PUT /domains/:id` (the current row with the changes; scope `domains`) | the owner's dialog (replacing an A record) |
| `server domain apply\|nginx\|purge DOMAIN` | `POST /domains/:id/apply` · `…/deploy-nginx` (`domains`) · `…/purge-cache` (`dns`) | |
| `server cloudflare purge\|ssl\|ssl-full BASE` | `POST /cloudflare/purge-zone` · `GET /cloudflare/ssl?domain=` · `POST /cloudflare/ssl-full` `{"base_domain"}` (`dns`) | |
| `server pg databases\|users SERVER` | `GET /servers/:id/pg/databases` · `…/pg/users` (scope `databases`) | |
| `server pg user-add SERVER USERNAME PROJECT` · `pg grant SERVER USER DB [--revoke]` | `POST …/pg/users` `{"username","project_id"}` · `…/pg/users/:name/grant` `{"database","revoke"?}` | |
| `server pg clone SERVER DB TARGET [--project P] [--wait]` | `POST …/pg/databases/:name/clone` `{"target_name","project_id"?}` | |
| `server server-env get\|set SERVER …` | `GET`/`POST /servers/:id/env` `{"key","value"}` (admin token) | |
| `server domain check DOMAIN` | `GET /domains/check?name=` (scope `read`) → `{"domain","available","premium","price","renewal_price","currency","price_cap","purchase_allowed","reason"}` (1.4: `+ "balance","balance_currency"`) | |
| `server balance [--refresh]` | `GET /registrar/balance[?refresh=1]` (scope `read`, 1.4) → `{"available_balance","account_balance","currency","low_threshold","low","checked_at"}` | |
| `server domain buy DOMAIN --approval DECISION_ID [--years 1\|2] [--no-dns]` | `POST /domains/purchase` `{"domain","years","approval_ref","setup_dns"}` (scope `domains_buy`, admin token) → 201 `{"domain","years","charged_amount","currency","order_id","purchase_id","nameservers","cloudflare_zone","whois_privacy"}` | **always** the owner's purchase dialog (confirm = the domain) |

- SERVER, PROJECT, DOMAIN: an id or a name (FQDN for domains). `scan PATH` scans the registered dir
  the path is in and, for a project's own folder, prints that project.
- **Deploys are autonomous:** if the panel asks for a confirmation (v1), the app sends it and logs
  "confirmed automatically". `deploy --wait` prints the deployment id, then new log lines and status
  changes, and exits 0 on success or 1 on failure (with the error). Every other 428 asks the
  owner (see **Owner approvals** below); refused, or no answer in time: `403 owner_refused`, exit 4.
- **v1.1 commands** (`dirs`, `scan`, `ports`, `project`, `env`, `dockerfile`, `db`, `domain`,
  `dns`, `cloudflare`, `zone`, `ns`, `static`, `sync`): a panel whose `/me` lacks the command's
  scope (`projects_write`, `databases`, `domains`, `dns`, `deploy`) or says it's older than 1.1,
  or that answers 404 for a read-only one or for `static add` / `sync`, answers `501
  not_available` ("not available: ServerPlan doesn't offer this yet"), exit 4.
- **Static sites** (no container; nginx serves the files with SSL, clean URLs by default):
  `static add` creates the root site of BASE in `/opt/static/<base with dashes>`; `domain add
  --static` a subdomain's, in `/opt/static/<sub>-<base with dashes>` unless `--target` is given.
  `sync` resolves FOLDER to an absolute path (symlinks resolved), the app checks it's a folder, and
  the panel uploads it to the site's target and prints where; a folder outside the registered
  project dirs is `403 not_in_project_dir`, exit 4. A site that already exists, or a bad value
  ("gecersiz …"), is the panel's 400, exit 1.
- **v1.2 commands** (`sql`, `local`, `local-env`, `db clone-for-local` / `clone-status`, `git`,
  `refresh`, `build`, `pull-deploy`, `diagnose`, `deploy-cancel`, `domain set|apply|nginx|purge`,
  `cloudflare purge|ssl|ssl-full`, `pg`, `server-env`), `env rescan` and `env rm`: gated like the v1.1 ones
  (the token's scope, the panel's version, and a 404 from a panel without the route). New scopes:
  `sql` (read-only SQL), `sql_write` (writing SQL), `local` (local runs and local-only env).
  A 404 that is a real answer stays exit 5: `local logs` (not running locally), `local-env unset`
  (no override for that key), `db clone-status` (unknown job), `deploy-cancel` (unknown deployment),
  `env rm` (no such row in the project; a panel older than ServerPlan 427bfe6 answers the same).
- **Owner's dialog** for every v1.2 428: `sql --write` (the panel names the database), `git push`,
  `git switch`, `diagnose fix`, `deploy-cancel` (the project's display name), `domain set` when it
  would replace an A record (the FQDN), `env rm` (the key). Only `deploy` is confirmed automatically.
- **SQL**: one statement; reads run in a read-only transaction on the panel and print a table
  (`--json`: `{database, columns, rows, row_count, truncated}`, at most 1000 rows), writes print
  psql's output. `--local` uses the local env's `DB_NAME` (a copy from `db clone-for-local`).
  `-` reads the query from stdin.
- **Local runs** run the project in Docker on the panel's machine, with the deploy env plus the
  local-only overrides (`local-env`); the default server (for the database) is the project's.
  `local run --wait` / `local status --wait` poll `local-status` until the run is `running` (exit 0)
  or `failed` / `stopped` / not running (exit 1); while it's `building` the polling goes on as
  before (each request waits up to 25 s, `124` = ask again). The verdict is the panel's `status`, never a probe of the port:
  since ServerPlan faa8398 the panel re-checks the container (`docker inspect`) on every status
  read and fails a run whose host port is already taken (`error: Port N dolu: …`), so another app
  answering `localhost:N` doesn't pass for the project. `running` with a non-empty `error` is a
  failure too; every failure prints the panel's `error:` line, and a failed run prints no URL.
  Unknown states count as failures. A panel that sends no `status` is
  judged by its `running` flag, as before. Plain `local status` (no `--wait`) reports the same
  line and error with exit 0. An already running project is `409 conflict`, exit 1.
- **Database copies**: `db clone-for-local` copies the project's database (its `DB_NAME`, or
  `--database`) on its server (or `--server`) to `TARGET` (default `<db>_dev`) and points only the
  local env's `DB_NAME` at it; the deploy env is unchanged. `pg clone … --project P` is the
  panel's own clone: it **switches P's deploy env `DB_NAME`** to the copy (its next deploy uses
  it), and the command says so. Both print the job; `--wait` polls `/pg/clone-jobs/:id`.
  `clone-for-local` also answers `"grant_db_user"` when the project has its own `DB_USER`: the
  panel grants that user access to the copy once the clone finishes (the copy is owned by the
  server's admin user); the command prints it.
- `pull-deploy` prints the deployment id like `deploy` (`--wait` follows it); its server is
  `--server` or the project's. `pg user-add` writes `DB_USER` / `DB_PASSWORD` to the project's
  env; the password is never returned. `domain set` sends the domain's current values with the
  changes (the panel replaces every field).
- `env set`, `local-env set` and `server-env set` take `KEY=VALUE` lines from `--from-file FILE`
  or stdin (`-`) so secrets stay out of the shell history; `--secret KEY` marks secrets (`env set`
  only; `local-env` and `server-env` treat keys with PASSWORD, SECRET, KEY, TOKEN, PRIVATE or
  CREDENTIAL as secret). Values are never printed, only the keys.
- **Project env rows**: `env get` shows each row's id (`ID` column; `id` in `--json`). A key can
  exist more than once (e.g. a double import); the precedence is "latest updated wins" (rows are
  merged in `updated_at` order, so the most recently edited value is used). `env rm PROJECT
  ENV_ID` deletes one row after the owner confirms with its key and prints how many copies of the
  key remain (none: the key is gone from the deploy env).
- **DATABASE_URL**: a server-level `DATABASE_URL` (admin user @ the `postgres` database) is
  rewritten per project from its `DB_*` values (when it has `DB_NAME`, `DB_USER` and `DB_HOST`) unless the project env or the local env (local
  runs) sets `DATABASE_URL` itself; local runs use the local DB values.
- **Domains (v1.3)**: offered only when `/me` says 1.3 or later or lists `domain_check` /
  `domain_purchase` (and the token has the scope: `read`, `domains_buy`); otherwise `501
  not_available`, exit 4. `domain check` prints whether it's available, the first year's price
  and the renewal with the currency, premium, the owner's price cap, and whether an agent may buy
  it (and why not).
- **`domain buy` spends real money** (the Namecheap balance), so:
  - `--approval` must be the id (`d_…`) of a `claudedeck decide` decision the owner **answered**
    (not pending, not cancelled) whose question or answer names the domain (any case). Otherwise
    ClaudeDeck refuses before calling the panel: `400 bad_approval`, exit 2 ("ask the owner first
    with claudedeck decide, then pass its id"). The id goes to the panel as `approval_ref`.
  - The panel's 428 (domain, years, price, renewal, currency) is always the owner's purchase
    dialog, whatever any setting says: it says plainly that it's a real purchase charged to the
    Namecheap balance; Cancel is the default (Return and Escape), only "Buy" ("Satın Al") says
    yes; no answer within the approval wait time is a no (`403 owner_refused`, exit 4; nothing is
    bought). Only then is it sent again with `confirm` = the domain.
  - The panel's refusals, with a hint: `400 no_approval_ref` (exit 2), `412 purchase_disabled`
    (turned off in ServerPlan › Entegrasyonlar › Namecheap) / `412 not_configured` (exit 4),
    `409 conflict` (already bought, or not available; exit 1), `403 premium_domain` / `price_cap`
    (exit 4), `402 insufficient_balance` (exit 4), `502 registrar_error` (exit 1).
  - 201 prints the domain, years, the amount charged and currency, the order id, the nameservers,
    the Cloudflare zone and WHOIS privacy; `--json` passes the panel's object through. The command
    waits up to 330 s (2 minutes for the owner, then up to 3 for the registrar). The purchase and
    every refusal are in the Activity Log, and a bought domain is a Mac (and phone) notification.
- **Namecheap balance (v1.4)**: offered only when `/me` says 1.4 or later or lists
  `registrar_balance` (scope `read`). `server balance` prints the available and account balance
  with the currency, the panel's low threshold (or "none set in ServerPlan"), `LOW` with where to
  top up (Namecheap › Billing › Add Funds) or `low: no`, and when the panel last asked Namecheap
  (it caches 5 minutes; `--refresh` asks again). `412 not_configured` (no Namecheap in the panel,
  exit 4), `502 registrar_error` (exit 1). On a 1.4 panel `domain check` also prints `balance:`,
  and when the balance can't cover the first year the panel says `purchase: not allowed: bakiye
  yetersiz: X` (the command adds the top-up hint); the two balance fields are left out when the
  panel couldn't read the balance.
- **Low-balance alert on the Mac and the phone**: Settings › ServerPlan shows the Namecheap balance
  (with a refresh button) and the "Namecheap balance alert (USD)" setting (default 20, 0 = off);
  the sidebar's Servers section has a small "Namecheap: X USD" line (orange when low). The balance
  is read when the section or Settings opens, every 30 minutes while a window is visible, and on
  refresh. When it goes under the threshold (the panel's `low_threshold`, else the setting), the
  owner gets one notification on the Mac and a push on the phone ("Namecheap balance is low: 15
  USD (threshold 20 USD). Top up for domain purchases: Namecheap › Billing › Add Funds."), once
  per crossing: the panel's `registrar.low_balance` event and a low fetch count as the same
  crossing, and the state is kept per panel across relaunches. `registrar.balance_ok`, or a fetch
  at or above the threshold, re-arms it (and withdraws the notification). A panel without
  Namecheap (412) shows nothing. The phone's Servers screen shows the balance from Macs with
  `Feature.registrarBalance` (`RemoteServerPlan.registrarBalance`).
- **Mock**: `tools/serverplan-mock.py --v14 [--balance N] [--low-threshold N] [--namecheap
  unconfigured]`; `POST /_demo/balance?value=N` moves the balance and emits the events on a crossing.
  In the demo: `CLAUDEDECK_SERVERPLAN_DEMO=1 CLAUDEDECK_SERVERPLAN_MOCK_ARGS="--v14 --balance 15" tools/demo.sh`.
  `--v15` adds `/ratelimit` (`--cloudflare unconfigured`: 412); `--v16` (alias `--containers`) serves
  ServerPlan 1.6's container API with its real shapes and errors (details, inspect, stats, numbers
  on health, logs `since`/`until`/`grep`/`timestamps`, exec terminals, recreate / pull / remove,
  docker disk / prune; traefik's pull and staging's prune fail with `502 action_failed`), and
  `--container-events SECONDS` plays `container.*` events (crash, unhealthy, restart loop, a stop,
  OOM, recreate) on `/events`. The mock's `/domains` rows carry no `fqdn`, like the panel's, and
  include a root static site (`@`).
- **Containers**: `container … status|inspect|env|logs` and `stats SERVER` work on any panel
  (status and env are built from the container list, the domains and the projects with the
  panel's own rule: an app domain's container is `lower(target)` or `lower(project_name)`, a static
  site's `nginx-<sub>-<base with dashes>`). An unknown container is `404 unknown_container`, exit 5
  (the message lists the server's containers); a container that isn't a ServerPlan project's has no
  env (`404 no_project`). `container … stats|recreate|pull|remove`, `disk` and `prune` are offered
  only when `/me` lists their feature (`container_stats`, `container_recreate`, `image_update`,
  `container_remove`, `docker_prune`; all shipped in ServerPlan 1.6, docs/serverplan-containers.md),
  never on a version alone; otherwise `501 not_available`, exit 4. Recreate, pull, remove and prune
  wait up to 330 s (the owner's 2 minutes, then docker). `logs --grep` filters the fetched tail (the
  tail applies first) until the panel has `log_query`; `--since`, `--until` and `--timestamps` need
  `log_query`. Logs of an unknown container are the panel's 502 (or an empty answer with `--grep`):
  the CLI checks the container list and answers `404 unknown_container`, exit 5. A shell inside a
  container (`container_exec`) is the owner's own, from the app; it isn't offered to agents.
  Container events (`container.*` on `/events`) notify the owner; there is no `server events`
  command.
- **Rate limiting (1.5, `ratelimit`)**: `ratelimit set HOST` limits `/init` to 20 requests per 10 s
  per IP by default; `--paths` takes absolute paths (comma separated, `*` only at the end),
  `--rate N/Ms` or `N/Mm`. Cloudflare Free allows one rule per zone: replacing the zone's rule is the
  panel's 428 with both rules in the summary, which goes to the owner; `ratelimit clear` always is.
  Refusals with hints: `412 not_configured` (the Cloudflare token isn't set in ServerPlan ›
  Entegrasyonlar › Cloudflare; exit 4), `404 no_zone` (no Cloudflare zone for the base domain;
  `server zone add BASE`; exit 5), `400` (bad host or path; exit 2), `502 cloudflare_error` (the
  panel's token needs Zone › Zone WAF › Edit; exit 1). Webhook paths are better left unlimited
  (RevenueCat and Apple send from shared IPs).
- **Domain names**: the panel stores a root domain as subdomain `@` (quick-static) or `""`; it
  resolves and lists as the bare base domain (`veilnum.com`), any other as `sub.base`. `domain
  list` prints a TYPE and an FQDN column and `--json` adds `fqdn` to each row.
- **Slow panel calls**: domain writes (`POST /domains`, `PUT /domains/:id`, `quick-static`,
  `sync`, `apply`, `deploy-nginx`), `auto-create-db`, the database clones, `domains/purchase` and
  `project-dirs/:id/scan` apply Traefik / nginx / Cloudflare or run SSH before they answer, so the app
  waits 180 s for them (the command's curl longer). When `domain add`'s answer is lost to a timeout
  anyway, the app looks for the FQDN on that server (three times, 5 s apart): a row that wasn't
  there before counts as created ("created; the panel answered slowly", `"slow_answer": true`),
  exit 0. Retrying is safe: the panel answers `409 conflict` for an FQDN it has.
- Reads aren't logged one by one (`--wait` polls); every change and every refusal is in the
  Activity Log.

### Owner approvals (`claudedeck approval …`)

A `claudedeck server` command the owner must approve (a ServerPlan 428 gate, a domain purchase)
puts a card in the Mac's **Approvals** tab (a sidebar tray, a notification, and the **Approvals**
row on the iPhone and iPad, which also lists the last 7 days of answered, refused, expired and
cancelled ones). The Mac card and the paired phone approve everything (the phone asks once more for a purchase or a refusal); a notification never approves a purchase; nothing is ever approved automatically.

- **How long:** Settings › Agents › **Approval wait time** ("Onay bekleme süresi"): 15 min, 1 hour,
  4 hours, **24 hours** (default) or no limit. Purchases use the same setting. No answer by then:
  refused (`expired`), and logged in the Activity Log like a refusal.
- **Nothing holds a request open for that long.** The command's first request answers `202`, exit
  `75`, `pending approval a_… (expires in …): TITLE` as soon as the approval is asked for. The
  script then prints `claudedeck: waiting for the owner to approve a_… in ClaudeDeck` on stderr and
  long-polls `GET /v1/cli/approvals/a_…/wait?timeout=25` (25 s rounds, like `claudedeck wait`)
  until the command has answered; it ends with that command's own output and exit code (0, or 4
  `owner_refused` / `approval_expired`). ClaudeDeck not answering is retried for up to 10
  minutes; if a restart made the terminal's token invalid (401), the wait ends with exit 75 and a
  notice: the approval stays pending and its result is queued for the session.
- **`--no-wait`** (any `server` command): prints `pending approval a_…` (with `--json`: the
  status object) and exits **75** at once.
- **The command runs in ClaudeDeck, not in the script.** When the owner approves, ClaudeDeck sends
  the gated request again with the panel's `confirm`, exactly as the waiting call would have, even
  if the script is gone. The result goes to the asking Claude session as a queued one-line
  message (unless a waiting script already printed it):
  `[ClaudeDeck approval a_…] Owner approved: TITLE → RESULT`, or `… Owner refused: TITLE`, or
  `… Expired with no answer from the owner: TITLE`.
- **Kept across restarts:** pending approvals are saved in Application Support/`approvals.json`
  and stay pending and answerable after a relaunch. Approved then, ClaudeDeck runs the command
  again; the owner's yes covers the first gate with the same command and target (for a purchase,
  also the same price summary), anything else asks again. Approvals a phone asked for itself
  (container start/stop) are withdrawn at relaunch.
- **Changing a refusal ("Approve anyway", "Yine de onayla"):** for **24 hours** after a refusal or
  an expiry, the Mac's Approvals tab (Recent) and the phone's approval history offer **Approve
  anyway** (a purchase: **Buy anyway**, with the price summary and the real-purchase warning in the
  confirmation; every change asks once). ClaudeDeck keeps the call behind a refused or expired
  approval in `approvals.json` for that window and drops it afterwards. The window is fixed and
  doesn't follow the approval wait time: that setting is how long a session waits for an answer,
  the window is how long the owner has to notice a wrong tap. Approved anyway, ClaudeDeck runs
  the kept call itself, the same way as an approval answered after a relaunch: the owner's yes
  covers the first gate with the same command and target (a purchase also needs the same price
  summary; if the panel's price changed, a new card asks again), anything else asks again. The
  approval then reads `approved` with `changed_from` (`approval status`: `a_… approved (was
  refused): TITLE → RESULT`), `approval wait` returns the new run's answer, the change and the
  result go to the Activity Log, and the asking session gets a queued message:
  ``[ClaudeDeck approval a_…] The owner changed the answer to approved; ClaudeDeck ran `server
  container recreate web`: RESULT``. A session that was stopped by another session resumes for it
  (as with `send` and decision answers, when automatic resume is on); one the owner stopped keeps
  it in its queue for its next start; with the session gone it's only logged. Not offered for:
  cancelled approvals, approvals with no `claudedeck server` call behind them (Remote Control
  off, a phone's own container actions), approvals refused by ClaudeDeck 0.6.28 or earlier (their call
  was deleted when they were refused), or after the 24 hours. The phone needs a Mac with
  `Feature.reapproveApproval` (`RemoteMessage.reapproveApproval(id:)`; history items carry
  `reapprovableUntil`, `changedFrom`, `changedAt`).
- **No "un-approve".** An approval is acted on the moment it's approved: ClaudeDeck sends the
  gated request right away, so there's no window in which a yes could be taken back before it
  runs. Undo it with the opposite command (start what was stopped, and so on) instead.

| Command | Does |
|---|---|
| `claudedeck approval status ID [--json]` | `pending approval a_… (expires in 23 h 59 min): TITLE`, or `a_… approved: TITLE → RESULT` / `refused` / `expired` / `cancelled` (changed by the owner: `a_… approved (was refused): …`). JSON: `{"id","status","title","command","target","session","created_at","expires_at","resolved_at","result","changed_from"}` (`expires_at` absent: no limit; `changed_from` only on a changed answer). |
| `claudedeck approval wait ID [--timeout S] [--json]` | waits for the command behind it and prints its answer with its exit code; `--timeout` ran out first: exit 75. |
| `claudedeck approval cancel ID [--json]` | withdraws a pending one this session asked for (`403 not_yours` otherwise, `409 not_pending` once answered); no message follows. |

Errors: `404 unknown_approval` (exit 5). Token scope: `server`.

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
