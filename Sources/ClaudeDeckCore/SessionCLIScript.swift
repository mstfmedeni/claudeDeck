import Foundation

extension SessionCLI {
    /// `<Application Support>/ClaudeDeck/bin/claudedeck`, written on launch while the setting is
    /// on. Like `claudedeck-ask` it holds no secret: the token is in the session's environment.
    /// A script and not a binary: nothing to sign or bundle, and it always matches the running app;
    /// the rules live in the API (SessionCLI).
    public static let script = #"""
    #!/bin/sh
    # claudedeck: ClaudeDeck from inside the terminals it starts. `claudedeck help` for usage.
    # Exit codes: 0 ok/finished, 1 failed or error, 2 usage, 3 blocked, 4 refused, 5 unknown id,
    # 6 limited (wait: the session waits for its usage limit to reset), 124 timeout
    # (docs/agents.md in the ClaudeDeck repository).

    usage() {
      cat <<'EOF'
    claudedeck: work with ClaudeDeck from the session (or terminal) it started.

      claudedeck list [--json]
          Sessions and terminals, with their state; "self" is this one, "mine" ones it opened.
      claudedeck open [--split right|left|down|none] [--cwd DIR] [--name NAME] [--json] [--] [COMMAND...]
          A plain terminal next to this session running COMMAND; prints its id.
          One argument is a shell command line ("npm run dev"); several are run as given.
      claudedeck send ID TEXT [--enter|--no-enter] [--json]
          Types TEXT (- reads stdin) into a terminal this session opened or one beside it.
          A Claude session gets it submitted (queued if it's working; --no-enter only types it);
          a plain terminal only with --enter. Another Claude session gets it as a note unless
          the user lets sessions type into Claude.
      claudedeck capture ID [--lines N] [--trim] [--json]
          The screen and scrollback as text.
      claudedeck wait ID [--timeout SECONDS] [--json]
          Until the terminal's command finishes, or a Claude session is idle or needs the user.
          ID may be a queue id (new --queue): it waits for the start, then for the session.
          A Claude session at its usage limit: 6 while it waits for the reset; one moving to
          another account (Settings > Accounts) keeps running, so wait keeps waiting.
      claudedeck wait --all|--any ID... [--timeout SECONDS] [--json]
          --all: until every one stopped running (3 if any needs the user, else 1 if any
          failed, else 0). --any: until the first one does, with its code.
      claudedeck close ID|self [--force] [--json]
          Ends this session or one it started, like End Session (it stays in the sidebar and
          can be resumed), and closes its pane. An idle Claude gets /exit (up to 15 s); --force
          ends the process when Claude is busy, blocked or doesn't leave. "self" ends after the
          current turn (--force: right away). Needs "Sessions may close sessions they started".
      claudedeck notify TEXT
          A notification for the user.
      claudedeck ask [--agent NAME] QUESTION
          A question for the user, as a note beside this session (or for an agent you may ask).
      claudedeck status ID [--json]
          A session's state, who started it, the stall watch and the simulators it holds.
      claudedeck usage [--project ID|NAME|PATH] [--json]
          Each project's share of the plan's 5-hour and weekly usage (tokens, estimated cost).
      claudedeck skill setup [--user|--project] [--force]
          Installs the Claude Code skill that explains this command.

    Claude accounts (Settings > Accounts):
      claudedeck account list [--json]
          Every account: priority, 5-hour and weekly usage, limited / near its limit, reset,
          sessions; "active" is where new sessions start, "current" is this session's.
      claudedeck account current [--json]
          This session's account.
      claudedeck account switch [--to NAME] [--json]
          Moves this session to another account (default: the first with room): it ends and
          resumes the same conversation there a moment after this prints. Nothing else to do.

    Decisions for the owner (don't wait: the answer comes later as a message). Write them in Turkish:
      claudedeck decide QUESTION [--options "A,B,C"] [--recommend A] [--context TEXT] [--project P]
                        [--supersedes ID] [--json]
          Asks the owner and returns at once with the decision's id (d_...). Keep working.
          --context - reads stdin. --project: id, name or path (default: this session's).
          --supersedes ID cancels that pending one and asks this instead (both or neither).
          The same question already waiting from this session: prints its id, nothing new.
      claudedeck decision get ID [--json]
          pending, answered: ANSWER, or cancelled: REASON.
      claudedeck decision cancel ID [--reason TEXT] [--json]
          Withdraws a pending decision this session (or one it started) asked.
      claudedeck decisions [--pending] [--json]
          Every decision, newest first.
    Simulators (Settings > Agents: "Sessions may reserve simulators"):
      claudedeck sim acquire [--device "iPhone 17 Pro"] [--duo] [--json]
          Simulators of this session's own, booted: prints "UDID  NAME" per device. --duo adds an
          iPhone Duo. No other session gets them until they're released.
      claudedeck sim release [UDID] [--json]
          Releases one (or, without UDID, all of this session's). Also when the session ends.
      claudedeck sim list [--json]
          The held simulators (and their holders) and ClaudeDeck's free ones.

    Projects and sessions (Settings > Agents: "Sessions may add projects and start Claude sessions"):
      claudedeck projects [--json]
          The deck's projects: id, sessions, group, name, path.
      claudedeck project add PATH [--name NAME] [--group GROUP] [--create] [--json]
          Adds a folder as a project (an existing one: returns it). --create makes the folder,
          only under your home folder. Prints the project id.
      claudedeck new [--project ID|NAME|PATH] [--name NAME] [--prompt TEXT] [--worktree NAME]
                     [--permission-mode MODE] [--allow RULE]... [--model MODEL] [--effort LEVEL]
                     [--skill NAME] [--account NAME|auto] [--queue] [--json]
          Starts a Claude session (in this session's project by default) and types TEXT once
          Claude is up. Prints the session id; wait, capture and send work on it.
          MODE: default, acceptEdits, plan, auto, dontAsk, manual, bypassPermissions (needs its
          own setting, as does a rule allowing every shell command: Bash, "Bash(*)"). RULE: a tool rule for claude --allowedTools ("Bash(git *)", Edit).
          LEVEL: low, medium, high, xhigh, max. --skill starts with /NAME (TEXT as its arguments).
          --queue: over the cap or rate limit, waits in a queue instead; prints a queue id (q_...).
          --account: the Claude account (account list); auto: the first with room. Default: the
          project's pinned account, else the one new sessions use.
      claudedeck preset show [PROJECT] [--json]
      claudedeck preset set PROJECT [--permission-mode MODE] [--allow RULE]... [--model MODEL] [--effort LEVEL]
      claudedeck preset clear PROJECT
          Options new uses in PROJECT when it isn't given them (a flag replaces that field).
      claudedeck queue list [--json] | queue show QID [--json] | queue cancel QID
          Queued starts; show prints the session id once it started.

    ServerPlan (Settings > Agents: "Sessions may use ServerPlan"):
      claudedeck server list | projects | dirs | features | cloudflare | deployments [--project P]
      claudedeck server health|containers|ports SERVER
      claudedeck server logs SERVER CONTAINER [--tail N] [--follow]
      claudedeck server deploy PROJECT [--server S] [--force] [--wait]
      claudedeck server deploy-status DEPLOYMENT [--wait]
      claudedeck server container SERVER CONTAINER start|stop|restart   (the owner confirms)
      claudedeck server scan DIR-ID|PATH
      claudedeck server project show PROJECT
      claudedeck server project set PROJECT [--server S] [--port N] [--volume PATH] [--dockerfile PATH]
      claudedeck server env get PROJECT
      claudedeck server env set PROJECT [--from-file FILE | -] [--secret KEY]... [KEY=VALUE...]
      claudedeck server dockerfile template PROJECT | dockerfile write PROJECT (--from-file FILE | -) [--port N]
      claudedeck server db create PROJECT
      claudedeck server domain list [--server S]
      claudedeck server domain add PROJECT SUBDOMAIN BASE [--server S] [--port N] [--websocket] [--target T]
      claudedeck server domain add --static SERVER SUBDOMAIN BASE [--target /opt/static/DIR] [--no-clean-urls]
      claudedeck server static add SERVER BASE      (the root static site of BASE)
      claudedeck server sync DOMAIN FOLDER          (upload a static site's files)
      claudedeck server dns sync DOMAIN | zone add NAME | ns set DOMAIN
      claudedeck server env rescan PROJECT [--dry-run]   (new keys from .env.example)
      claudedeck server sql PROJECT QUERY|- [--local] [--write]   (--write: the owner confirms)
      claudedeck server local run PROJECT [--server S] [--port N] [--no-cache] [--wait]
      claudedeck server local status PROJECT [--wait] | local logs PROJECT [--tail N] | local stop PROJECT
      claudedeck server local-env get PROJECT | local-env set PROJECT [--from-file FILE | -] [KEY=VALUE...]
      claudedeck server local-env unset PROJECT KEY...
      claudedeck server db clone-for-local PROJECT [--server S] [--database DB] [--target NAME] [--wait]
      claudedeck server db clone-status JOB [--wait]
      claudedeck server git branches|pull|push PROJECT | git switch PROJECT BRANCH   (push, switch: the owner confirms)
      claudedeck server refresh PROJECT | build PROJECT [--no-cache]
      claudedeck server pull-deploy PROJECT [--server S] [--force] [--wait]
      claudedeck server diagnose PROJECT | diagnose fix PROJECT ACTION   (fix: the owner confirms)
      claudedeck server deploy-cancel DEPLOYMENT   (the owner confirms)
      claudedeck server domain set DOMAIN [--server S] [--port N] [--target T] [--project P]
          [--[no-]websocket] [--[no-]clean-urls] [--[no-]ssl]   (replacing an A record: the owner confirms)
      claudedeck server domain apply|nginx|purge DOMAIN
      claudedeck server cloudflare purge|ssl|ssl-full BASE
      claudedeck server pg databases|users SERVER | pg user-add SERVER USERNAME PROJECT
      claudedeck server pg grant SERVER USER DB [--revoke] | pg clone SERVER DB TARGET [--project P] [--wait]
      claudedeck server server-env get SERVER | server-env set SERVER [--from-file FILE | -] [KEY=VALUE...]
          SERVER, PROJECT: an id or a name. Not every panel has every command: see server features.

    ID: an id from `claudedeck list`, its first 8 characters, or "self".
    Exit codes: 0 ok/finished, 1 failed (or another error), 2 usage, 3 blocked (needs the user),
    4 refused, 5 unknown id, 6 limited (waits for its usage limit to reset), 124 timeout.
    EOF
    }

    die() { printf 'claudedeck: %s\n' "$1" >&2; exit "${2:-2}"; }

    need_session() {
      if [ -z "${CLAUDEDECK_CLI_TOKEN:-}" ] || [ -z "${CLAUDEDECK_CLI_URL:-}" ]; then
        die "only works in a terminal ClaudeDeck started while Settings > Agents > Command-line tool for sessions was on." 2
      fi
    }

    fmt() { if [ "$json" = 1 ]; then echo json; else echo text; fi; }

    check_id() {
      [ -n "$1" ] || die "$2: which one? See claudedeck list."
      case "$1" in *[!A-Za-z0-9_-]*) die "$2: not an id: $1" ;; esac
    }

    # call PATH CURL-ARGS...: the answer's body in $body, its exit code in $code.
    call() {
      path=$1; shift
      out=$(curl -sS -m "${max_time:-40}" \
        -w '\n%{http_code} e=%header{x-claudedeck-exit} n=%header{x-claudedeck-next} m=%header{x-claudedeck-note}' \
        -H "Authorization: Bearer $CLAUDEDECK_CLI_TOKEN" "$@" "$CLAUDEDECK_CLI_URL$path" 2>&1)
      status=$(printf '%s\n' "$out" | tail -n 1)
      body=$(printf '%s\n' "$out" | sed '$d')
      # "<http> e=<exit header> n=<next header> m=<note header>"; any header may be missing
      # (empty after its prefix, so the fields never shift).
      set -- $status
      http=${1:-000}; code=${2#e=}; next=${3#n=}; note=${4#m=}
      case "$http" in
        000) die "ClaudeDeck isn't answering. Is it running, with Settings > Agents > Local API on?" 1 ;;
      esac
      if [ -z "$code" ]; then
        case "$http" in
          404) die "the command-line tool is off in ClaudeDeck (Settings > Agents)." 4 ;;
          2??) code=0 ;;
          400|405) code=2 ;;
          401|403|429) code=4 ;;
          *) code=1 ;;
        esac
      fi
    }

    # Prints the answer and exits with its code (errors go to stderr unless --json).
    finish() {
      case "$http" in
        2??) [ -n "$body" ] && printf '%s\n' "$body" ;;
        *)
          if [ "$json" = 1 ]; then
            printf '%s\n' "$body"
          else
            reason=$(printf '%s' "$body" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')
            message=$(printf '%s' "$body" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
            case "$reason" in
              setting_off) hint=" (not allowed in ClaudeDeck: Settings > Agents > Command-line tool)" ;;
              too_many_starts|too_many_projects|too_many_running) hint=" (rate limit or cap; try later, or new --queue)" ;;
              too_many_queued) hint=" (the queue is full; try later)" ;;
              bypass_off) hint=" (bypassPermissions is off in ClaudeDeck: Settings > Agents > Command-line tool)" ;;
              bad_permission_mode) hint=" (default, acceptEdits, plan, auto, dontAsk, manual or bypassPermissions)" ;;
              bad_effort) hint=" (low, medium, high, xhigh or max)" ;;
              bad_allow) hint=" (a tool rule like Edit or \"Bash(git *)\")" ;;
              unknown_skill) hint=" (no such skill in ~/.claude/skills, the project's .claude/skills or a plugin)" ;;
              unknown_queue_id) hint=" (see claudedeck queue list)" ;;
              queued) hint=" (still queued; claudedeck wait QID)" ;;
              queue_cancelled|queue_failed) hint=" (see claudedeck queue show QID)" ;;
              unknown_project) hint=" (see claudedeck projects)" ;;
              owner_refused) hint=" (the owner refused or didn't answer in ClaudeDeck)" ;;
              serverplan_off) hint=" (ServerPlan isn't set up in ClaudeDeck)" ;;
              not_available) hint="" ;;
              not_allowed) hint=" (this session's token doesn't allow that)" ;;
              not_yours) case "$command_name" in
                  close) hint=" (only this session and the sessions it started)" ;;
                  decide|decision) hint=" (only the session that asked it, or one that started that session)" ;;
                  *) hint=" (only terminals this session opened, or ones beside it)" ;;
                esac ;;
              close_off) hint=" (not allowed in ClaudeDeck: Settings > Agents > \"Sessions may close sessions they started\")" ;;
              busy) hint=" (Claude is working; wait for it, or close --force)" ;;
              still_running) hint=" (Claude didn't leave after /exit; close --force ends it)" ;;
              read_only) hint=" (it runs in another app's session helper)" ;;
              unknown_session) hint=" (see claudedeck list)" ;;
              ambiguous) hint=" (give more of the id)" ;;
              not_running) hint=" (it isn't running)" ;;
              blocked) hint=" (a permission or a question is on screen)" ;;
              bad_recommend) hint=" (--recommend must be one of --options, or its number)" ;;
              too_many_options) hint=" (at most 10 options)" ;;
              too_many_pending|too_many) hint=" (too many questions waiting; wait for answers)" ;;
              unknown_decision) hint=" (see claudedeck decisions)" ;;
              already_answered) hint=" (the owner answered it already; see claudedeck decision get)" ;;
              already_cancelled) hint=" (it was cancelled already)" ;;
              unknown_account) hint=" (see claudedeck account list)" ;;
              no_account) hint=" (no other account has room; see claudedeck account list)" ;;
              account_limited) hint=" (that account is at its usage limit)" ;;
              not_logged_in) hint=" (nobody is logged in on that account: Settings > Accounts)" ;;
              pinned) hint=" (this session or its project is pinned to its account)" ;;
              same_account) hint=" (already on that account)" ;;
              switching) hint=" (already moving)" ;;
              switching_account) hint=" (it is being moved to another account; try again in a moment)" ;;
              too_many_simulators) hint=" (at most 4 per session; release some first)" ;;
              unknown_device) hint=" (no such simulator device type; see xcrun simctl list devicetypes)" ;;
              no_runtime) hint=" (no installed runtime runs that device type)" ;;
              not_held) hint=" (no session holds that simulator)" ;;
              simctl_failed) hint="" ;;
              *) hint="" ;;
            esac
            printf 'claudedeck: %s%s%s (HTTP %s)\n' "${reason:-$body}" "${message:+: $message}" "$hint" "$http" >&2
          fi
          ;;
      esac
      exit "$code"
    }

    # An argument as a shell reads it back: bare when it's plain, else in single quotes.
    quote() {
      case "$1" in
        ""|*[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
      esac
    }

    cmd_list() {
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          *) die "list: unknown option $1" ;;
        esac
        shift
      done
      need_session
      call /sessions -G --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_open() {
      split=right; cwd=""; name=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --split) [ $# -ge 2 ] || die "open: --split needs right, left, down or none"; split=$2; shift ;;
          --split=*) split=${1#*=} ;;
          --cwd) [ $# -ge 2 ] || die "open: --cwd needs a folder"; cwd=$2; shift ;;
          --cwd=*) cwd=${1#*=} ;;
          --name) [ $# -ge 2 ] || die "open: --name needs a name"; name=$2; shift ;;
          --name=*) name=${1#*=} ;;
          --json) json=1 ;;
          --) shift; break ;;
          -*) die "open: unknown option $1" ;;
          *) break ;;
        esac
        shift
      done
      case "$split" in right|left|down|none) ;; *) die "open: --split is right, left, down or none" ;; esac
      if [ -n "$cwd" ]; then
        [ -d "$cwd" ] || die "open: no such folder: $cwd"
        cwd=$(cd "$cwd" && pwd -P)
      fi
      if [ $# -eq 1 ]; then
        command=$1
      else
        command=""
        for arg in "$@"; do command="$command${command:+ }$(quote "$arg")"; done
      fi
      need_session
      call /terminals --data-urlencode "command=$command" --data-urlencode "cwd=$cwd" --data-urlencode "name=$name" \
        --data-urlencode "split=$split" --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_send() {
      enter=""; id=""; text=""; have_text=0; options=1
      while [ $# -gt 0 ]; do
        case "$options:$1" in
          1:--enter) enter=1 ;;
          1:--no-enter) enter=0 ;;
          1:--json) json=1 ;;
          1:--) options=0 ;;
          1:-?*) die "send: unknown option $1 (use -- before text that starts with -)" ;;
          *)
            if [ -z "$id" ]; then id=$1
            elif [ "$have_text" = 0 ]; then text=$1; have_text=1
            else die "send: one TEXT only (quote it)"
            fi
            ;;
        esac
        shift
      done
      check_id "$id" send
      [ "$have_text" = 1 ] || [ "$enter" = 1 ] || die "send: nothing to send (TEXT, or --enter for Return)"
      [ "$text" = "-" ] && text=$(cat)
      need_session
      call "/sessions/$id/send" --data-urlencode "text=$text" --data-urlencode "enter=$enter" --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_capture() {
      id=""; lines=""; trim=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --lines) [ $# -ge 2 ] || die "capture: --lines needs a number"; lines=$2; shift ;;
          --lines=*) lines=${1#*=} ;;
          --trim) trim=1 ;;
          --json) json=1 ;;
          -*) die "capture: unknown option $1" ;;
          *) [ -z "$id" ] || die "capture: one ID only"; id=$1 ;;
        esac
        shift
      done
      check_id "$id" capture
      case "$lines" in ""|*[!0-9]*) [ -z "$lines" ] || die "capture: --lines needs a number" ;; esac
      need_session
      call "/sessions/$id/screen" -G --data-urlencode "lines=$lines" --data-urlencode "trim=$trim" --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_wait() {
      id=""; ids=""; mode=""; timeout=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --timeout) [ $# -ge 2 ] || die "wait: --timeout needs seconds"; timeout=$2; shift ;;
          --timeout=*) timeout=${1#*=} ;;
          --all|--any) [ -z "$mode" ] || [ "$mode" = "${1#--}" ] || die "wait: --all or --any, not both"; mode=${1#--} ;;
          --json) json=1 ;;
          -*) die "wait: unknown option $1" ;;
          *)
            check_id "$1" wait
            if [ -z "$id" ]; then id=$1; fi
            ids="$ids${ids:+,}$1"
            ;;
        esac
        shift
      done
      check_id "$id" wait
      [ -n "$mode" ] || [ "$id" = "$ids" ] || die "wait: one ID only (or --all / --any ID...)"
      case "$timeout" in ""|*[!0-9]*) die "wait: --timeout needs whole seconds (0: no limit)" ;; esac
      need_session
      start=$(date +%s)
      while :; do
        window=25
        if [ "$timeout" -gt 0 ]; then
          left=$((timeout - ($(date +%s) - start)))
          [ "$left" -lt 0 ] && left=0
          [ "$left" -lt "$window" ] && window=$left
        fi
        max_time=$((window + 15))
        if [ -n "$mode" ]; then
          call /wait -G --data-urlencode "ids=$ids" --data-urlencode "mode=$mode" --data-urlencode "timeout=$window" \
            --data-urlencode "format=$(fmt)"
        else
          call "/sessions/$id/wait" -G --data-urlencode "timeout=$window" --data-urlencode "format=$(fmt)"
        fi
        if [ "$code" = 124 ] && { [ "$timeout" -eq 0 ] || [ $((timeout - ($(date +%s) - start))) -gt 0 ]; }; then
          continue
        fi
        finish
      done
    }

    cmd_close() {
      id=""; force=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --force) force=1 ;;
          --json) json=1 ;;
          -*) die "close: unknown option $1" ;;
          *) [ -z "$id" ] || die "close: one ID only"; id=$1 ;;
        esac
        shift
      done
      check_id "$id" close
      need_session
      # Up to 15 s for Claude to leave after /exit, then the end of the process.
      max_time=60
      call "/sessions/$id/close" --data-urlencode "force=$force" --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_notify() {
      [ "${1:-}" = "--" ] && shift
      [ $# -gt 0 ] || die "notify: what should it say?"
      need_session
      call /notify --data-urlencode "text=$*"
      finish
    }

    cmd_ask() {
      agent=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --agent) [ $# -ge 2 ] || die "ask: --agent needs a name"; agent=$2; shift ;;
          --agent=*) agent=${1#*=} ;;
          --) shift; break ;;
          -*) die "ask: unknown option $1" ;;
          *) break ;;
        esac
        shift
      done
      [ $# -gt 0 ] || die "ask: what's the question?"
      need_session
      call /ask --data-urlencode "agent=$agent" --data-urlencode "question=$*"
      finish
    }

    # check_decision_id ID COMMAND: a d_ id, letters and digits only.
    check_decision_id() {
      [ -n "$1" ] || die "$2: which one? See claudedeck decisions."
      case "$1" in d_*) ;; *) die "$2: not a decision id: $1 (they start with d_)" ;; esac
      case "$1" in *[!A-Za-z0-9_]*) die "$2: not a decision id: $1" ;; esac
    }

    cmd_decide() {
      question=""; options=""; recommend=""; context=""; project=""; supersedes=""; have_q=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --options) [ $# -ge 2 ] || die "decide: --options needs \"A,B,C\""; options=$2; shift ;;
          --options=*) options=${1#*=} ;;
          --recommend) [ $# -ge 2 ] || die "decide: --recommend needs one of the options"; recommend=$2; shift ;;
          --recommend=*) recommend=${1#*=} ;;
          --context) [ $# -ge 2 ] || die "decide: --context needs text (- reads stdin)"; context=$2; shift ;;
          --context=*) context=${1#*=} ;;
          --project) [ $# -ge 2 ] || die "decide: --project needs an id, name or path"; project=$2; shift ;;
          --project=*) project=${1#*=} ;;
          --supersedes) [ $# -ge 2 ] || die "decide: --supersedes needs the id of the decision it replaces"; supersedes=$2; shift ;;
          --supersedes=*) supersedes=${1#*=} ;;
          --json) json=1 ;;
          --) shift
              if [ $# -gt 0 ]; then
                [ "$have_q" = 0 ] || die "decide: one QUESTION only (quote it)"
                question=$1; have_q=1; shift
              fi
              [ $# -eq 0 ] || die "decide: one QUESTION only (quote it)"
              break ;;
          -?*) die "decide: unknown option $1" ;;
          *) [ "$have_q" = 0 ] || die "decide: one QUESTION only (quote it)"; question=$1; have_q=1 ;;
        esac
        shift
      done
      [ -n "$question" ] || die "decide: what's the question?"
      [ -z "$supersedes" ] || check_decision_id "$supersedes" "decide --supersedes"
      [ "$context" = "-" ] && context=$(cat)
      case "$project" in
        /*|./*|../*) project=$(abs_path "$project") ;;
      esac
      need_session
      call /decisions --data-urlencode "question=$question" --data-urlencode "options=$options" \
        --data-urlencode "recommend=$recommend" --data-urlencode "context=$context" --data-urlencode "project=$project" \
        --data-urlencode "supersedes=$supersedes" --data-urlencode "format=$(fmt)"
      # Warnings that don't stop it (X-ClaudeDeck-Note: comma-separated codes).
      case "$http" in
        2??)
          case ",$note," in
            *,already_pending:*)
              existing=${note#*already_pending:}; existing=${existing%%,*}
              printf 'decide: already pending as %s\n' "$existing" >&2 ;;
          esac
          case ",$note," in
            *,not_turkish,*) printf '%s\n' "decide: owner-facing text should be Turkish (soru Türkçe olmalı)" >&2 ;;
          esac
          ;;
      esac
      finish
    }

    cmd_decision() {
      sub=${1:-}
      case "$sub" in
        get|cancel) shift ;;
        *) die "decision: try claudedeck decision get ID, or claudedeck decision cancel ID [--reason TEXT]" ;;
      esac
      id=""; reason=""
      while [ $# -gt 0 ]; do
        case "$sub:$1" in
          *:--json) json=1 ;;
          cancel:--reason) [ $# -ge 2 ] || die "decision cancel: --reason needs text"; reason=$2; shift ;;
          cancel:--reason=*) reason=${1#*=} ;;
          *:-*) die "decision $sub: unknown option $1" ;;
          *) [ -z "$id" ] || die "decision $sub: one ID only"; id=$1 ;;
        esac
        shift
      done
      check_decision_id "$id" "decision $sub"
      need_session
      if [ "$sub" = cancel ]; then
        call "/decisions/$id/cancel" --data-urlencode "reason=$reason" --data-urlencode "format=$(fmt)"
      else
        call "/decisions/$id" -G --data-urlencode "format=$(fmt)"
      fi
      finish
    }

    cmd_decisions() {
      pending=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --pending) pending=1 ;;
          --json) json=1 ;;
          *) die "decisions: unknown option $1" ;;
        esac
        shift
      done
      need_session
      call /decisions -G --data-urlencode "pending=$pending" --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_projects() {
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          *) die "projects: unknown option $1" ;;
        esac
        shift
      done
      need_session
      call /projects -G --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_status() {
      id=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          -*) die "status: unknown option $1" ;;
          *) [ -z "$id" ] || die "status: one ID only"; id=$1 ;;
        esac
        shift
      done
      [ -n "$id" ] || id=self
      check_id "$id" status
      need_session
      call "/sessions/$id/status" -G --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_usage() {
      project=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --project) [ $# -ge 2 ] || die "usage: --project needs an id, name or path"; project=$2; shift ;;
          --project=*) project=${1#*=} ;;
          --json) json=1 ;;
          *) die "usage: unknown argument $1" ;;
        esac
        shift
      done
      case "$project" in ./*|../*) project=$(abs_path "$project") ;; esac
      need_session
      max_time=120
      call /usage -G --data-urlencode "project=$project" --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_sim() {
      sub=${1:-}; [ $# -gt 0 ] && shift
      device=""; duo=0; udid=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --device) [ $# -ge 2 ] || die "sim: --device needs a device type (\"iPhone 17 Pro\")"; device=$2; shift ;;
          --device=*) device=${1#*=} ;;
          --duo) duo=1 ;;
          --json) json=1 ;;
          -*) die "sim: unknown option $1" ;;
          *) [ -z "$udid" ] || die "sim: one UDID only"; udid=$1 ;;
        esac
        shift
      done
      case "$sub" in
        acquire)
          [ -z "$udid" ] || die "sim acquire: no arguments besides --device and --duo"
          need_session
          # Creating and booting a simulator can take minutes.
          max_time=600
          call /sim/acquire --data-urlencode "device=$device" --data-urlencode "duo=$duo" --data-urlencode "format=$(fmt)" ;;
        release)
          case "$udid" in *[!A-Fa-f0-9-]*) die "sim release: not a UDID: $udid" ;; esac
          need_session
          call /sim/release --data-urlencode "udid=$udid" --data-urlencode "format=$(fmt)" ;;
        list)
          need_session
          call /sim -G --data-urlencode "format=$(fmt)" ;;
        *) die "sim: acquire, release or list (claudedeck help)" ;;
      esac
      finish
    }

    # An absolute path for PATH (relative ones are from here; the folder needn't exist).
    abs_path() {
      case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$(pwd -P)" "${1#./}" ;;
      esac
    }

    cmd_project() {
      [ "${1:-}" = add ] || die "project: try claudedeck project add PATH [--name NAME] [--group GROUP] [--create]"
      shift
      path=""; name=""; group=""; create=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --name) [ $# -ge 2 ] || die "project add: --name needs a name"; name=$2; shift ;;
          --name=*) name=${1#*=} ;;
          --group) [ $# -ge 2 ] || die "project add: --group needs a name"; group=$2; shift ;;
          --group=*) group=${1#*=} ;;
          --create) create=1 ;;
          --json) json=1 ;;
          -*) die "project add: unknown option $1" ;;
          *) [ -z "$path" ] || die "project add: one PATH only"; path=$1 ;;
        esac
        shift
      done
      [ -n "$path" ] || die "project add: which folder?"
      need_session
      call /projects --data-urlencode "path=$(abs_path "$path")" --data-urlencode "name=$name" \
        --data-urlencode "group=$group" --data-urlencode "create=$create" --data-urlencode "format=$(fmt)"
      finish
    }

    # Launch options shared by new and preset set: permission mode, allowed tools (one per line),
    # model, effort. Returns 1 when $1 isn't one of them (the caller handles it); sets $taken.
    launch_option() {
      taken=1
      case "$1" in
        --permission-mode) [ $# -ge 2 ] || die "$cmd: --permission-mode needs a mode"; mode=$2; taken=2 ;;
        --permission-mode=*) mode=${1#*=} ;;
        --allow) [ $# -ge 2 ] || die "$cmd: --allow needs a tool rule"; add_allow "$2"; taken=2 ;;
        --allow=*) add_allow "${1#*=}" ;;
        --model) [ $# -ge 2 ] || die "$cmd: --model needs a model"; model=$2; taken=2 ;;
        --model=*) model=${1#*=} ;;
        --effort) [ $# -ge 2 ] || die "$cmd: --effort needs low, medium, high, xhigh or max"; effort=$2; taken=2 ;;
        --effort=*) effort=${1#*=} ;;
        *) return 1 ;;
      esac
      return 0
    }

    add_allow() {
      case "$1" in *"
    "*) die "$cmd: --allow takes one rule per flag" ;; esac
      [ -n "$1" ] || die "$cmd: --allow needs a tool rule"
      allow="$allow${allow:+
    }$1"
    }

    check_launch_options() {
      case "$mode" in ""|default|manual|acceptEdits|plan|auto|dontAsk|bypassPermissions) ;;
        *) die "$cmd: --permission-mode is default, acceptEdits, plan, auto, dontAsk, manual or bypassPermissions" ;; esac
      case "$effort" in ""|low|medium|high|xhigh|max) ;; *) die "$cmd: --effort is low, medium, high, xhigh or max" ;; esac
    }

    # A project reference in a URL path (an absolute path for ./ and ../).
    project_ref() {
      p=$1
      case "$p" in
        /*|./*|../*) p=$(abs_path "$p") ;;
      esac
      printf '%s' "$p" | sed 's/%/%25/g; s/\//%2F/g; s/ /%20/g; s/?/%3F/g; s/#/%23/g'
    }

    cmd_new() {
      cmd=new; project=self; name=""; prompt=""; worktree=""; mode=""; allow=""; model=""; effort=""; skill=""; queue=0; account=""
      while [ $# -gt 0 ]; do
        if launch_option "$@"; then shift "$taken"; continue; fi
        case "$1" in
          --skill) [ $# -ge 2 ] || die "new: --skill needs a skill name"; skill=$2; shift ;;
          --skill=*) skill=${1#*=} ;;
          --queue) queue=1 ;;
          --account) [ $# -ge 2 ] || die "new: --account needs a name or auto"; account=$2; shift ;;
          --account=*) account=${1#*=} ;;
          --project) [ $# -ge 2 ] || die "new: --project needs an id, name or path"; project=$2; shift ;;
          --project=*) project=${1#*=} ;;
          --name) [ $# -ge 2 ] || die "new: --name needs a name"; name=$2; shift ;;
          --name=*) name=${1#*=} ;;
          --prompt) [ $# -ge 2 ] || die "new: --prompt needs text (- reads stdin)"; prompt=$2; shift ;;
          --prompt=*) prompt=${1#*=} ;;
          --worktree) [ $# -ge 2 ] || die "new: --worktree needs a name"; worktree=$2; shift ;;
          --worktree=*) worktree=${1#*=} ;;
          --json) json=1 ;;
          *) die "new: unknown argument $1" ;;
        esac
        shift
      done
      [ -n "$project" ] || die "new: --project needs an id, name or path"
      [ "$prompt" = "-" ] && prompt=$(cat)
      check_launch_options
      skill=${skill#/}
      case "$skill" in *[!A-Za-z0-9._:-]*) die "new: --skill is a skill name (letters, digits, . _ - and plugin:name)" ;; esac
      case "$account" in *[!a-z0-9-]*) die "new: --account is an account name (see claudedeck account list) or auto" ;; esac
      ref=$(project_ref "$project")
      need_session
      call "/projects/$ref/sessions" --data-urlencode "name=$name" --data-urlencode "prompt=$prompt" \
        --data-urlencode "worktree=$worktree" --data-urlencode "permission_mode=$mode" --data-urlencode "allow=$allow" \
        --data-urlencode "model=$model" --data-urlencode "effort=$effort" --data-urlencode "skill=$skill" \
        --data-urlencode "queue=$queue" --data-urlencode "account=$account" --data-urlencode "format=$(fmt)"
      finish
    }

    cmd_preset() {
      cmd=preset; action=${1:-show}
      [ $# -gt 0 ] && shift
      case "$action" in show|set|clear) ;; *) die "preset: try claudedeck preset show|set|clear PROJECT" ;; esac
      cmd="preset $action"; project=""; mode=""; allow=""; model=""; effort=""
      while [ $# -gt 0 ]; do
        if [ "$action" = set ] && launch_option "$@"; then shift "$taken"; continue; fi
        case "$1" in
          --json) json=1 ;;
          -*) die "$cmd: unknown option $1" ;;
          *) [ -z "$project" ] || die "$cmd: one PROJECT only"; project=$1 ;;
        esac
        shift
      done
      check_launch_options
      need_session
      if [ "$action" = show ] && [ -z "$project" ]; then
        call /presets -G --data-urlencode "format=$(fmt)"
        finish
      fi
      [ -n "$project" ] || die "$cmd: which project? (an id, a name, a path or self)"
      ref=$(project_ref "$project")
      case "$action" in
        show) call "/projects/$ref/preset" -G --data-urlencode "format=$(fmt)" ;;
        set)
          [ -n "$mode$allow$model$effort" ] || die "preset set: give --permission-mode, --allow, --model or --effort (preset clear removes it)"
          call "/projects/$ref/preset" --data-urlencode "permission_mode=$mode" --data-urlencode "allow=$allow" \
            --data-urlencode "model=$model" --data-urlencode "effort=$effort" --data-urlencode "format=$(fmt)" ;;
        clear) call "/projects/$ref/preset" --data-urlencode "clear=1" --data-urlencode "format=$(fmt)" ;;
      esac
      finish
    }

    cmd_queue() {
      action=${1:-list}
      [ $# -gt 0 ] && shift
      id=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          -*) die "queue $action: unknown option $1" ;;
          *) [ -z "$id" ] || die "queue $action: one QID only"; id=$1 ;;
        esac
        shift
      done
      case "$action" in
        list) [ -z "$id" ] || die "queue list takes no id"; need_session; call /queue -G --data-urlencode "format=$(fmt)" ;;
        show) check_id "$id" "queue show"; need_session; call "/queue/$id" -G --data-urlencode "format=$(fmt)" ;;
        cancel) check_id "$id" "queue cancel"; need_session; call "/queue/$id/cancel" --data-urlencode "format=$(fmt)" ;;
        *) die "queue: try claudedeck queue list | show QID | cancel QID" ;;
      esac
      finish
    }

    cmd_account() {
      action=${1:-list}
      [ $# -gt 0 ] && shift
      to=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --to) [ "$action" = switch ] && [ $# -ge 2 ] || die "account: --to NAME goes with switch"; to=$2; shift ;;
          --to=*) [ "$action" = switch ] || die "account: --to goes with switch"; to=${1#*=} ;;
          --json) json=1 ;;
          *) die "account $action: unknown argument $1" ;;
        esac
        shift
      done
      case "$to" in *[!a-z0-9-]*) die "account switch: --to is an account name (see claudedeck account list)" ;; esac
      need_session
      case "$action" in
        list) call /accounts -G --data-urlencode "format=$(fmt)" ;;
        current) call /accounts/current -G --data-urlencode "format=$(fmt)" ;;
        switch) call /accounts/switch --data-urlencode "to=$to" --data-urlencode "format=$(fmt)" ;;
        *) die "account: try claudedeck account list | current | switch [--to NAME]" ;;
      esac
      finish
    }

    # claudedeck server …: the app calls ServerPlan (this command never has its token).
    srv() { # NAME [GET] CURL-ARGS...
      srv_name=$1; shift
      if [ "${1:-}" = GET ]; then shift; set -- -G "$@"; fi
      call "/server/$srv_name" "$@" --data-urlencode "format=$(fmt)"
    }

    # Follows a deploy: new log lines and status changes until it ends (0 success, 1 failed).
    deploy_wait() {
      since=0; last=""
      while :; do
        max_time=45
        srv deploy-status GET --data-urlencode "id=$1" --data-urlencode "wait=25" --data-urlencode "since=$since" \
          --data-urlencode "status=$last"
        case "$http" in 2??) ;; *) finish ;; esac
        [ -n "$body" ] && printf '%s\n' "$body"
        if [ -n "$next" ]; then since=${next%%:*}; last=${next#*:}; fi
        [ "$code" = 124 ] && continue
        exit "$code"
      done
    }

    # poll_wait COMMAND PARAM VALUE: long polls (25 s each) a local run or a clone job until it
    # ends, printing what's new (0 done, 1 failed).
    poll_wait() {
      since=""
      while :; do
        max_time=45
        srv "$1" GET --data-urlencode "$2=$3" --data-urlencode "wait=25" --data-urlencode "since=$since"
        case "$http" in 2??) ;; *) finish ;; esac
        [ -n "$body" ] && printf '%s\n' "$body"
        [ -n "$next" ] && since=$next
        [ "$code" = 124 ] && continue
        exit "$code"
      done
    }

    cmd_server() {
      sub=${1:-}; [ $# -gt 0 ] && shift
      case "$sub" in
        ""|help) usage; exit 0 ;;
        env|local-env|server-env) cmd_server_vars "$sub" "$@"; return ;;
      esac
      p1=""; p2=""; p3=""; p4=""; n=0
      wait=0; follow=0; force=0; websocket=0; stdin=0; file=""; static=0; clean=1
      tail=""; server=""; sproject=""; sname=""; port=""; volume=""; dockerfile=""; target=""
      local_db=0; write=0; no_cache=0; revoke=0; database=""; ws=""; clean_set=""; ssl=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          --static) static=1 ;;
          --no-clean-urls) clean=0; clean_set=0 ;;
          --clean-urls) clean_set=1 ;;
          --wait) wait=1 ;;
          --follow|-f) follow=1 ;;
          --force) force=1 ;;
          --websocket) websocket=1; ws=1 ;;
          --no-websocket) ws=0 ;;
          --ssl) ssl=1 ;;
          --no-ssl) ssl=0 ;;
          --local) local_db=1 ;;
          --write) write=1 ;;
          --no-cache) no_cache=1 ;;
          --revoke) revoke=1 ;;
          --from-file) [ $# -ge 2 ] || die "server $sub: --from-file needs a file"; file=$2; shift ;;
          -) stdin=1 ;;
          --tail|--server|--project|--name|--port|--volume|--dockerfile|--target|--database)
            [ $# -ge 2 ] || die "server $sub: $1 needs a value"
            case "$1" in
              --tail) tail=$2 ;; --server) server=$2 ;; --project) sproject=$2 ;; --name) sname=$2 ;;
              --port) port=$2 ;; --volume) volume=$2 ;; --dockerfile) dockerfile=$2 ;; --target) target=$2 ;;
              --database) database=$2 ;;
            esac
            shift ;;
          -*) die "server $sub: unknown option $1" ;;
          *)
            n=$((n + 1))
            case $n in 1) p1=$1 ;; 2) p2=$1 ;; 3) p3=$1 ;; 4) p4=$1 ;; *) die "server $sub: too many arguments" ;; esac
            ;;
        esac
        shift
      done
      for number in "$tail" "$port"; do
        case "$number" in ""|*[!0-9]*) [ -z "$number" ] || die "server $sub: not a number: $number" ;; esac
      done
      args() { [ "$n" -eq "$1" ] || die "server $sub: $2"; }
      case "$sub" in
        list|projects|dirs|features|cloudflare|deployments|health|containers|ports|logs|deploy|deploy-status|container|scan|project|dockerfile|db|domain|dns|zone|ns|static|sync) ;;
        sql|local|git|refresh|build|pull-deploy|diagnose|deploy-cancel|pg) ;;
        *) die "server: unknown command $sub (claudedeck help)" ;;
      esac
      case "$sub" in
        list|projects|dirs|features|deployments) args 0 "no arguments" ;;
        cloudflare) case "$p1" in "") ;; purge|ssl|ssl-full) args 2 "cloudflare $p1 BASE" ;;
          *) die "server cloudflare: purge, ssl or ssl-full BASE" ;; esac ;;
        sql) if [ "$stdin" = 1 ]; then args 1 "sql PROJECT - (the query on stdin)"; else args 2 "sql PROJECT QUERY"; fi ;;
        local) case "$p1" in run|status|logs|stop) args 2 "local $p1 PROJECT" ;;
          *) die "server local: run, status, logs or stop PROJECT" ;; esac ;;
        git) case "$p1" in branches|pull|push) args 2 "git $p1 PROJECT" ;; switch) args 3 "git switch PROJECT BRANCH" ;;
          *) die "server git: branches, pull or push PROJECT, or switch PROJECT BRANCH" ;; esac ;;
        refresh|build|pull-deploy) args 1 "which project?" ;;
        diagnose) if [ "$p1" = fix ]; then args 3 "diagnose fix PROJECT ACTION"; else args 1 "diagnose PROJECT"; fi ;;
        deploy-cancel) args 1 "which deployment?"; case "$p1" in *[!0-9]*) die "server deploy-cancel: a deployment id" ;; esac ;;
        pg) case "$p1" in databases|users) args 2 "pg $p1 SERVER" ;; user-add) args 4 "pg user-add SERVER USERNAME PROJECT" ;;
          grant) args 4 "pg grant SERVER USER DB" ;; clone) args 4 "pg clone SERVER DB TARGET" ;;
          *) die "server pg: databases, users, user-add, grant or clone" ;; esac ;;
        health|containers|ports) args 1 "which server?" ;;
        logs) args 2 "logs SERVER CONTAINER" ;;
        deploy) args 1 "which project?" ;;
        deploy-status) args 1 "which deployment?"; case "$p1" in *[!0-9]*) die "server deploy-status: a deployment id" ;; esac ;;
        container) args 3 "container SERVER CONTAINER start|stop|restart"
          case "$p3" in start|stop|restart) ;; *) die "server container: start, stop or restart" ;; esac ;;
        scan) args 1 "which folder?" ;;
        project) case "$p1" in show|set) args 2 "project $p1 PROJECT" ;; *) die "server project: show or set PROJECT" ;; esac ;;
        dockerfile) case "$p1" in template) args 2 "dockerfile template PROJECT" ;;
          write) args 2 "dockerfile write PROJECT"
            [ -n "$file" ] || [ "$stdin" = 1 ] || die "server dockerfile write: --from-file FILE or - (stdin)"
            [ -z "$file" ] || [ -r "$file" ] || die "server dockerfile write: can't read $file" ;;
          *) die "server dockerfile: template or write PROJECT" ;; esac ;;
        db) case "$p1" in create) args 2 "db create PROJECT" ;; clone-for-local) args 2 "db clone-for-local PROJECT" ;;
          clone-status) args 2 "db clone-status JOB" ;;
          *) die "server db: create PROJECT, clone-for-local PROJECT or clone-status JOB" ;; esac ;;
        domain) case "$p1" in list) args 1 "domain list" ;;
          add) if [ "$static" = 1 ]; then args 4 "domain add --static SERVER SUBDOMAIN BASE"; else args 4 "domain add PROJECT SUBDOMAIN BASE"; fi ;;
          set|apply|nginx|purge) args 2 "domain $p1 DOMAIN" ;;
          *) die "server domain: list, add, set, apply, nginx or purge" ;; esac ;;
        static) [ "$p1" = add ] || die "server static: try server static add SERVER BASE"; args 3 "static add SERVER BASE" ;;
        sync) args 2 "sync DOMAIN FOLDER"
          [ -d "$p2" ] || die "server sync: not a folder: $p2"
          # Absolute, symlinks resolved: the panel checks it's inside a registered project dir.
          folder=$(cd -P -- "$p2" && pwd -P) || die "server sync: can't open $p2" ;;
        dns) [ "$p1" = sync ] || die "server dns: try server dns sync DOMAIN"; args 2 "dns sync DOMAIN" ;;
        zone) [ "$p1" = add ] || die "server zone: try server zone add NAME"; args 2 "zone add NAME" ;;
        ns) [ "$p1" = set ] || die "server ns: try server ns set DOMAIN"; args 2 "ns set DOMAIN" ;;
      esac
      need_session
      case "$sub" in
        cloudflare)
          case "$p1" in
            "") srv cloudflare GET ;;
            purge) srv zone-purge --data-urlencode "base=$p2" ;;
            ssl) srv ssl GET --data-urlencode "base=$p2" ;;
            ssl-full) srv ssl-full --data-urlencode "base=$p2" ;;
          esac ;;
        list|projects|dirs|features) srv "$sub" GET ;;
        deployments) srv deployments GET --data-urlencode "project=$sproject" ;;
        health|containers) srv "$sub" GET --data-urlencode "server=$p1" ;;
        ports) srv ports GET --data-urlencode "server=$p1" ;;
        logs)
          if [ "$follow" = 1 ]; then
            first=${tail:-100}
            while :; do
              max_time=45
              srv logs GET --data-urlencode "server=$p1" --data-urlencode "container=$p2" --data-urlencode "tail=$first" --data-urlencode "follow=25"
              case "$http" in 2??) ;; *) finish ;; esac
              [ -n "$body" ] && printf '%s\n' "$body"
              first=0
              [ "$code" = 124 ] && continue
              exit "$code"
            done
          fi
          srv logs GET --data-urlencode "server=$p1" --data-urlencode "container=$p2" --data-urlencode "tail=$tail" ;;
        deploy)
          was_json=$json; json=0
          srv deploy --data-urlencode "project=$p1" --data-urlencode "server=$server" --data-urlencode "force=$force"
          json=$was_json
          case "$http" in 2??) ;; *) finish ;; esac
          if [ "$wait" = 1 ]; then printf '%s\n' "$body"; deploy_wait "$body"; fi
          if [ "$json" = 1 ]; then body="{\"deployment_id\":$body}"; fi
          ;;
        deploy-status)
          [ "$wait" = 1 ] && deploy_wait "$p1"
          srv deploy-status GET --data-urlencode "id=$p1" ;;
        container)
          # The owner has 2 minutes to answer in ClaudeDeck.
          max_time=150
          srv container --data-urlencode "server=$p1" --data-urlencode "container=$p2" --data-urlencode "action=$p3" ;;
        scan) case "$p1" in *[!0-9]*) dir=$(abs_path "$p1") ;; *) dir=$p1 ;; esac
          srv scan --data-urlencode "dir=$dir" ;;
        project)
          if [ "$p1" = show ]; then srv project-show GET --data-urlencode "project=$p2"
          else srv project-set --data-urlencode "project=$p2" --data-urlencode "server=$server" --data-urlencode "port=$port" \
              --data-urlencode "volume=$volume" --data-urlencode "dockerfile=$dockerfile"
          fi ;;
        dockerfile)
          if [ "$p1" = template ]; then srv dockerfile-template GET --data-urlencode "project=$p2"
          else
            if [ -n "$file" ]; then content=$(cat "$file"); else content=$(cat); fi
            srv dockerfile-write --data-urlencode "project=$p2" --data-urlencode "content=$content" --data-urlencode "port=$port"
          fi ;;
        db)
          case "$p1" in
            create) srv db-create --data-urlencode "project=$p2" ;;
            clone-for-local)
              srv db-clone-local --data-urlencode "project=$p2" --data-urlencode "server=$server" \
                --data-urlencode "database=$database" --data-urlencode "target=$target"
              case "$http" in 2??) ;; *) finish ;; esac
              if [ "$wait" = 1 ] && [ -n "$next" ]; then printf '%s\n' "$body"; poll_wait clone-status id "$next"; fi ;;
            clone-status)
              [ "$wait" = 1 ] && poll_wait clone-status id "$p2"
              srv clone-status GET --data-urlencode "id=$p2" ;;
          esac ;;
        sql)
          if [ "$stdin" = 1 ]; then query=$(cat); else query=$p2; fi
          # A write waits for the owner (2 minutes), then runs up to a minute.
          if [ "$write" = 1 ]; then max_time=220; else max_time=75; fi
          srv sql --data-urlencode "project=$p1" --data-urlencode "query=$query" --data-urlencode "local=$local_db" \
            --data-urlencode "write=$write" ;;
        local)
          case "$p1" in
            run)
              max_time=150
              srv local-run --data-urlencode "project=$p2" --data-urlencode "server=$server" --data-urlencode "port=$port" \
                --data-urlencode "no_cache=$no_cache"
              case "$http" in 2??) ;; *) finish ;; esac
              if [ "$wait" = 1 ]; then printf '%s\n' "$body"; poll_wait local-status project "$p2"; fi ;;
            status)
              [ "$wait" = 1 ] && poll_wait local-status project "$p2"
              srv local-status GET --data-urlencode "project=$p2" ;;
            logs) srv local-logs GET --data-urlencode "project=$p2" --data-urlencode "tail=$tail" ;;
            stop) max_time=75; srv local-stop --data-urlencode "project=$p2" ;;
          esac ;;
        git)
          case "$p1" in
            branches) max_time=75; srv branches GET --data-urlencode "project=$p2" ;;
            pull) max_time=150; srv git-pull --data-urlencode "project=$p2" ;;
            push) max_time=280; srv git-push --data-urlencode "project=$p2" ;;
            switch) max_time=280; srv switch-branch --data-urlencode "project=$p2" --data-urlencode "branch=$p3" ;;
          esac ;;
        refresh) max_time=75; srv refresh --data-urlencode "project=$p1" ;;
        build) max_time=1230; srv build --data-urlencode "project=$p1" --data-urlencode "no_cache=$no_cache" ;;
        pull-deploy)
          was_json=$json; json=0
          max_time=75
          srv pull-deploy --data-urlencode "project=$p1" --data-urlencode "server=$server" --data-urlencode "force=$force"
          json=$was_json
          case "$http" in 2??) ;; *) finish ;; esac
          if [ "$wait" = 1 ]; then printf '%s\n' "$body"; deploy_wait "$body"; fi
          if [ "$json" = 1 ]; then body="{\"deployment_id\":$body}"; fi
          ;;
        diagnose)
          if [ "$p1" = fix ]; then max_time=280; srv diagnose-fix --data-urlencode "project=$p2" --data-urlencode "action=$p3"
          else max_time=150; srv diagnose GET --data-urlencode "project=$p1"
          fi ;;
        deploy-cancel) max_time=150; srv deploy-cancel --data-urlencode "id=$p1" ;;
        pg)
          case "$p1" in
            databases) max_time=75; srv pg-databases GET --data-urlencode "server=$p2" ;;
            users) max_time=75; srv pg-users GET --data-urlencode "server=$p2" ;;
            user-add) max_time=75; srv pg-user-add --data-urlencode "server=$p2" --data-urlencode "username=$p3" --data-urlencode "project=$p4" ;;
            grant) max_time=75; srv pg-grant --data-urlencode "server=$p2" --data-urlencode "username=$p3" --data-urlencode "database=$p4" \
                --data-urlencode "revoke=$revoke" ;;
            clone)
              max_time=75
              srv pg-clone --data-urlencode "server=$p2" --data-urlencode "database=$p3" --data-urlencode "target=$p4" \
                --data-urlencode "project=$sproject"
              case "$http" in 2??) ;; *) finish ;; esac
              if [ "$wait" = 1 ] && [ -n "$next" ]; then printf '%s\n' "$body"; poll_wait clone-status id "$next"; fi ;;
          esac ;;
        domain)
          if [ "$p1" = set ]; then max_time=220
            srv domain-set --data-urlencode "domain=$p2" --data-urlencode "server=$server" --data-urlencode "port=$port" \
              --data-urlencode "target=$target" --data-urlencode "project=$sproject" --data-urlencode "websocket=$ws" \
              --data-urlencode "clean_urls=$clean_set" --data-urlencode "ssl=$ssl"
          elif [ "$p1" = apply ]; then max_time=150; srv domain-apply --data-urlencode "domain=$p2"
          elif [ "$p1" = nginx ]; then max_time=150; srv domain-nginx --data-urlencode "domain=$p2"
          elif [ "$p1" = purge ]; then max_time=150; srv domain-purge --data-urlencode "domain=$p2"
          elif [ "$p1" = list ]; then srv domain-list GET --data-urlencode "server=$server"
          elif [ "$static" = 1 ]; then max_time=150
            srv domain-add --data-urlencode "static=1" --data-urlencode "server=$p2" --data-urlencode "subdomain=$p3" --data-urlencode "base=$p4" \
              --data-urlencode "clean_urls=$clean" --data-urlencode "target=$target"
          else max_time=150
            srv domain-add --data-urlencode "project=$p2" --data-urlencode "subdomain=$p3" --data-urlencode "base=$p4" \
              --data-urlencode "server=$server" --data-urlencode "port=$port" --data-urlencode "websocket=$websocket" --data-urlencode "target=$target"
          fi ;;
        dns) max_time=150; srv dns-sync --data-urlencode "domain=$p2" ;;
        zone) srv zone-add --data-urlencode "name=$p2" ;;
        ns) max_time=150; srv ns-set --data-urlencode "domain=$p2" ;;
        static) max_time=150; srv static-add --data-urlencode "server=$p2" --data-urlencode "base=$p3" ;;
        sync) max_time=600; srv sync --data-urlencode "domain=$p1" --data-urlencode "path=$folder" ;;
      esac
      finish
    }

    # env / local-env / server-env: set reads values from stdin (-) or a file so secrets stay out
    # of the shell history; values are never printed. local-env: overrides only local runs see.
    cmd_server_vars() {
      kind=$1; shift
      action=${1:-}; [ $# -gt 0 ] && shift
      case "$kind:$action" in
        env:get|env:set|env:rescan|local-env:get|local-env:set|local-env:unset|server-env:get|server-env:set) ;;
        env:*) die "server env: get, set or rescan" ;;
        local-env:*) die "server local-env: get, set or unset" ;;
        *) die "server server-env: get or set" ;;
      esac
      project=""; vars=""; keys=""; secrets=""; file=""; stdin=0; dry_run=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          --dry-run) [ "$action" = rescan ] || die "$kind $action: unknown option $1"; dry_run=1 ;;
          --from-file) [ $# -ge 2 ] || die "$kind set: --from-file needs a file"; file=$2; shift ;;
          --from-file=*) file=${1#*=} ;;
          --secret) [ "$kind" = env ] || die "$kind: --secret is for env set"; [ $# -ge 2 ] || die "env set: --secret needs a key"
            secrets="$secrets${secrets:+,}$2"; shift ;;
          --secret=*) [ "$kind" = env ] || die "$kind: --secret is for env set"; secrets="$secrets${secrets:+,}${1#*=}" ;;
          -) stdin=1 ;;
          -*) die "$kind: unknown option $1" ;;
          *)
            if [ -z "$project" ]; then project=$1
            elif [ "$action" = unset ]; then keys="$keys${keys:+,}$1"
            else
              case "$1" in *=*) vars="$vars$1
    " ;; *) die "$kind set: KEY=VALUE, not $1" ;; esac
            fi
            ;;
        esac
        shift
      done
      if [ "$kind" = server-env ]; then
        [ -n "$project" ] || die "server-env $action: which server?"
        ref="server=$project"
      else
        [ -n "$project" ] || die "$kind $action: which project?"
        ref="project=$project"
      fi
      case "$kind:$action" in
        *:get)
          need_session
          case "$kind" in env) srv env-get GET --data-urlencode "$ref" ;; *) srv "$kind-get" GET --data-urlencode "$ref" ;; esac
          finish ;;
        env:rescan)
          need_session
          srv env-rescan --data-urlencode "$ref" --data-urlencode "dry_run=$dry_run"
          finish ;;
        local-env:unset)
          [ -n "$keys" ] || die "local-env unset PROJECT KEY..."
          need_session
          srv local-env-unset --data-urlencode "$ref" --data-urlencode "keys=$keys"
          finish ;;
      esac
      if [ -n "$file" ]; then
        [ -r "$file" ] || die "$kind set: can't read $file"
        vars="$vars$(cat "$file")
    "
      fi
      if [ "$stdin" = 1 ]; then vars="$vars$(cat)
    "; fi
      [ -n "$vars" ] || die "$kind set: KEY=VALUE arguments, --from-file FILE, or - for stdin"
      need_session
      srv "$kind-set" --data-urlencode "$ref" --data-urlencode "vars=$vars" --data-urlencode "secret=$secrets"
      finish
    }

    skill_text() {
      cat <<'SKILL'
    \#(skill)
    SKILL
    }

    cmd_skill() {
      [ "${1:-}" = setup ] || die "skill: try claudedeck skill setup [--user|--project] [--force]"
      shift
      where=user; force=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --user) where=user ;;
          --project) where=project ;;
          --force) force=1 ;;
          *) die "skill setup: unknown option $1" ;;
        esac
        shift
      done
      if [ "$where" = project ]; then
        root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
        dir="$root/.claude/skills/claudedeck"
      else
        dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/claudedeck"
      fi
      file="$dir/SKILL.md"
      new=$(skill_text | shasum -a 256 | cut -d ' ' -f 1)
      if [ -f "$file" ]; then
        # The last line records the hash of what ClaudeDeck wrote; anything else is the user's.
        marker=$(tail -n 1 "$file" | sed -n 's/^<!-- claudedeck-skill sha256:\([0-9a-f]*\) -->$/\1/p')
        have=$(sed '$d' "$file" | shasum -a 256 | cut -d ' ' -f 1)
        if [ -n "$marker" ] && [ "$have" = "$marker" ] && [ "$have" = "$new" ]; then
          echo "claudedeck: the skill is up to date: $file"; exit 0
        fi
        if [ "$force" = 0 ] && { [ -z "$marker" ] || [ "$have" != "$marker" ]; }; then
          die "$file was changed by hand; leaving it. Run again with --force to replace it." 4
        fi
      fi
      mkdir -p "$dir" || die "couldn't create $dir" 1
      tmp="$file.tmp.$$"
      if { skill_text && printf '<!-- claudedeck-skill sha256:%s -->\n' "$new"; } > "$tmp" && mv -f "$tmp" "$file"; then
        echo "claudedeck: installed the skill: $file"
      else
        rm -f "$tmp"; die "couldn't write $file" 1
      fi
    }

    json=0
    command_name=${1:-help}
    [ $# -gt 0 ] && shift
    case "$command_name" in
      help|-h|--help) usage ;;
      list) cmd_list "$@" ;;
      open) cmd_open "$@" ;;
      send) cmd_send "$@" ;;
      capture) cmd_capture "$@" ;;
      wait) cmd_wait "$@" ;;
      close) cmd_close "$@" ;;
      notify) cmd_notify "$@" ;;
      ask) cmd_ask "$@" ;;
      skill) cmd_skill "$@" ;;
      projects) cmd_projects "$@" ;;
      project) cmd_project "$@" ;;
      new) cmd_new "$@" ;;
      preset) cmd_preset "$@" ;;
      queue) cmd_queue "$@" ;;
      server) cmd_server "$@" ;;
      decide) cmd_decide "$@" ;;
      decision) cmd_decision "$@" ;;
      decisions) cmd_decisions "$@" ;;
      account|accounts) cmd_account "$@" ;;
      sim) cmd_sim "$@" ;;
      usage) cmd_usage "$@" ;;
      status) cmd_status "$@" ;;
      *) usage >&2; exit 2 ;;
    esac
    """# + "\n"

    /// The Claude Code skill `claudedeck skill setup` installs (SKILL.md, without its hash line).
    public static let skill = #"""
    ---
    name: claudedeck
    description: Run and watch processes next to this ClaudeDeck session with the `claudedeck` command - open a terminal beside you for a dev server, a watcher or a long test run, type into it, read its screen, wait for it to finish, and notify or ask the user, or leave the owner a decision to make without waiting for it; add projects and start other Claude sessions; list, deploy and watch ServerPlan servers, containers and deployments. Use when the environment has CLAUDEDECK_SESSION set (you run inside ClaudeDeck) and a command should keep running or be visible to the user instead of blocking your Bash tool, or when work needs a new project, a parallel Claude session or a deploy.
    ---

    # claudedeck

    You are running inside ClaudeDeck, a Mac app that hosts Claude Code sessions and plain
    terminals side by side. `claudedeck` lets you use that from your Bash tool. It only works when
    `CLAUDEDECK_SESSION` is set; if `claudedeck` isn't on PATH, use `"$CLAUDEDECK_CLI"`.

    ## When to use it

    - A process must keep running (dev server, `--watch`, a simulator log): open it in a terminal
      beside you instead of backgrounding it in your Bash tool. The user sees it, and you can read it.
    - A long build or test run: open it, then `wait` for it with a timeout and `capture` the end.
    - You need the user: `notify` for something they should look at, `ask` for a question
      (it appears as a note beside your session; the answer comes back as a normal message).
    - To see what another session or terminal is doing: `list`, then `capture`.

    Don't use it for quick commands; run those directly.

    ## Commands

    ```sh
    claudedeck list [--json]                       # sessions and terminals: id, kind, state, pane
    claudedeck open [--split right|left|down|none] [--cwd DIR] [--name NAME] -- COMMAND
                                                   # prints the new terminal's id
    claudedeck send ID "TEXT" [--enter]            # type into a terminal you opened
    claudedeck capture ID [--lines N] [--trim]     # screen + scrollback as text
    claudedeck wait ID [--timeout SECONDS]         # until the command finishes / Claude stops
    claudedeck notify "TEXT"
    claudedeck ask "QUESTION"                      # or: ask --agent NAME "QUESTION"
    ```

    ### Decisions for the owner (non-blocking)

    When a choice belongs to the owner (product direction, a trade-off, spending, anything you'd
    otherwise stop and ask about), ask with `decide` and **keep working** on what doesn't depend
    on it. It returns at once with an id; the owner answers on the Mac or the phone whenever they
    get to it, and **the answer arrives in this session as a normal message** starting with
    `[ClaudeDeck decision d_…]`.

    ```sh
    claudedeck decide "Önbellek için hangi veritabanı?" --options "Redis,SQLite,Hiçbiri" \
      --recommend Redis --context "Redis ayrı bir container ister; 1k rps altında SQLite yeter."
                                                   # prints d_1a2b3c4d5e
    claudedeck decision get d_1a2b3c4d5e           # "pending", "answered: Redis" or "cancelled: …"
    claudedeck decisions --pending                 # everything still waiting
    claudedeck decide "Önbellek için Redis mi, SQLite mı?" --options "Redis,SQLite" \
      --supersedes d_1a2b3c4d5e                    # replaces the old question (cancels it)
    claudedeck decision cancel d_1a2b3c4d5e --reason "artık gerekmiyor"
                                                   # withdraw one that's obsolete
    ```

    - **Write the question, the options and the context in Turkish**: the owner reads them.
      `decide` warns on stderr when the text doesn't look Turkish.
    - Don't wait, poll or sleep for the answer. Don't ask the same thing twice: `decisions` lists
      what's already waiting, and asking the same question again just prints the waiting one's id
      (with a note on stderr).
    - To change a question that's still waiting (new facts, other options), ask the new one with
      `--supersedes OLD_ID` instead of leaving both. When a question no longer matters (you found
      the answer, the plan changed), `decision cancel ID` it so the owner doesn't answer for
      nothing. Only the session that asked, or one that started it, may cancel (exit 4 `not_yours`).
    - The owner may also remove a question without answering; you then get a message
      `[ClaudeDeck decision d_…] The owner dismissed your question …`: don't wait for it.
    - The owner may change an answer later: `[ClaudeDeck decision d_…] The owner changed the answer
      to your question … (was: …)`. The newest answer counts; adjust what you did on the old one.
    - Give 2-5 short options and recommend one; put the facts the owner needs in `--context`.
      The owner may also answer in their own words.
    - Options are separated by commas; when one contains a comma, put one option per line
      instead: `--options $'Yes, behind a flag\nNo, ship it on'`.
    - At most 10 questions per 10 minutes per session (exit 4 `too_many`).

    `ID` is a full id from `list`, its first 8 characters, or `self`. Add `--json` for
    machine-readable output.

    ```sh
    claudedeck status ID                           # state, who started it, stall watch, simulators
    claudedeck usage [--project P]                 # each project's share of the 5-hour / weekly usage
    ```

    ### Simulators

    Only when the user turned on "Sessions may reserve simulators" (otherwise exit 4,
    `setting_off`). Use your own simulator instead of `booted` or a shared device name, so
    parallel sessions never drive the same one.

    ```sh
    udid=$(claudedeck sim acquire | head -1 | cut -d ' ' -f 1)   # booted iPhone 17 Pro of your own
    claudedeck sim acquire --device "iPad Pro 13-inch (M5)"      # another device type
    claudedeck sim acquire --duo          # an iPhone 17 Pro and an iPhone Duo (two lines)
    xcodebuild … -destination "id=$udid"                          # always by UDID
    claudedeck sim release [UDID]         # when done (also happens when your session ends)
    claudedeck sim list                   # who holds what
    ```

    - ClaudeDeck creates its own devices ("ClaudeDeck · iPhone 17 Pro · 1") and reuses free ones;
      the user's simulators are never handed out. At most 4 per session (exit 4 `too_many_simulators`).
    - Acquiring can take a minute or two (create + boot). `--json` gives `udid`, `name`, `runtime`.

    ### Projects and Claude sessions

    Only when the user turned on "Sessions may add projects and start Claude sessions"
    (otherwise exit 4 with `setting_off`; don't retry).

    ```sh
    claudedeck projects [--json]                   # id, sessions, group, name, path
    claudedeck project add PATH [--name N] [--group G] [--create]
                                                   # prints the project id; already a project: same id, exit 0
    claudedeck new [--project ID|NAME|PATH] [--name N] [--prompt TEXT] [--worktree NAME]
                                                   # prints the new session's id (default: your project)
    ```

    ```sh
    claudedeck new --permission-mode acceptEdits --allow "Bash(npm test *)" --allow Edit \
      --model sonnet --effort high --skill review --prompt "the cart module"
    claudedeck new --queue --prompt "…"            # over a limit: prints q_…; `wait q_…` works
    claudedeck wait --all ID1 ID2 [--timeout S]    # or --any: the first one to stop
    claudedeck preset set self --permission-mode acceptEdits --allow "Bash(swift test *)"
    claudedeck preset show [PROJECT] · preset clear PROJECT
    claudedeck queue list · queue show QID · queue cancel QID
    ```

    - `--permission-mode`: default, acceptEdits, plan, auto, dontAsk, manual; bypassPermissions
      only if the user allowed it (else exit 4 `bypass_off`; don't retry). `--allow` is a Claude
      Code tool rule, repeatable. A project's preset fills in what `new` doesn't give.
      Sessions started with a mode or rules may always run `claudedeck`.
    - `--skill NAME` starts the session with `/NAME` (the prompt becomes its arguments); the
      skill must exist (exit 5 `unknown_skill`).
    - `--create` makes the folder, only under the user's home folder.
    - `new` types `--prompt` once Claude is up. You may `send` to sessions you started, and
      `wait`/`capture` them like terminals.
    - Sessions you start don't stop at Claude Code's "do you trust this folder" question:
      ClaudeDeck trusts the folder first, if it's under the user's home (not a dot folder or
      ~/Library). Elsewhere the
      session waits for the user at that question: `capture` shows it; tell the user.
    - Limits: 5 new sessions per 10 minutes and 10 new projects per hour per session, 8
      started sessions running at once. Exit 4 (`too_many_…`) means wait; don't loop on it
      (`--queue` waits for you: the start happens once there's room).
    - The user gets a notification for each and can see them in the activity log. Start
      sessions only when parallel work really helps, and say why in the prompt.
    - If the user turned on the stall watch, a session you started that makes no progress for a
      while (or repeats the same error) may be nudged or restarted by ClaudeDeck, and the user
      gets a note beside your session; `claudedeck status ID` shows the watch's state.

    ### Closing sessions

    Only when the user turned on "Sessions may close sessions they started" (otherwise exit 4
    `close_off`; don't retry).

    ```sh
    claudedeck close ID [--force] [--json]         # a session you started (or one they started)
    claudedeck close self [--force]                # yourself, once this turn is over
    ```

    - Close a session you started once its work is done and you've read its result: it frees one
      of the 8 running slots (a queued `new --queue` starts in it). It ends like the user's End
      Session (an idle Claude gets `/exit`); the session stays in the sidebar with its history and
      the user can resume it. Prints `closed` (`--json`: `{"closed":true,"id":…,"forced":false}`).
    - Never sessions the user started (exit 4 `not_yours`). Claude busy: exit 1 `busy`; waiting on
      the user: exit 3 `blocked`; still there 15 s after `/exit`: exit 124 `still_running`. Use
      `--force` only when you mean to cut its work off.
    - `close self` returns at once (`closing: after this turn`) and the session ends when your
      turn is over; finish your reply first. The session that started you gets a note.

    ### ServerPlan

    Only when the user turned on "Sessions may use ServerPlan" and set up ServerPlan in ClaudeDeck.
    ClaudeDeck makes the calls; you never need or see the ServerPlan token.

    ```sh
    claudedeck server list                         # servers
    claudedeck server projects                     # ServerPlan projects (not ClaudeDeck's)
    claudedeck server health SERVER
    claudedeck server containers SERVER
    claudedeck server logs SERVER CONTAINER [--tail N] [--follow]
    claudedeck server deploy PROJECT [--server S] [--wait]   # prints the deployment id
    claudedeck server deploy-status ID [--wait]
    claudedeck server deployments [--project P]
    claudedeck server container SERVER CONTAINER start|stop|restart   # the user must approve
    claudedeck server features                     # which commands this panel offers
    ```

    Newer panels (v1.1; see `server features`, otherwise exit 4 "ServerPlan doesn't offer this yet"):

    ```sh
    claudedeck server dirs                         # registered project dirs (projects live in these)
    claudedeck server scan DIR-ID|PATH             # (re)scan; with a project's PATH prints that project
    claudedeck server ports SERVER                 # used ports, suggested_port, free ports
    claudedeck server project show PROJECT
    claudedeck server project set PROJECT [--server S] [--port N] [--volume P] [--dockerfile P]
    claudedeck server env get PROJECT              # secrets are never shown
    claudedeck server env set PROJECT --from-file .env.production [--secret KEY]...
    printf 'API_KEY=%s\n' "$KEY" | claudedeck server env set PROJECT - --secret API_KEY
    claudedeck server dockerfile template PROJECT | dockerfile write PROJECT --from-file Dockerfile
    claudedeck server db create PROJECT            # PostgreSQL; writes DB_NAME/DB_HOST/DB_PORT to the env
    claudedeck server domain list [--server S]
    claudedeck server domain add PROJECT SUBDOMAIN BASE [--server S] [--port N] [--websocket]
    claudedeck server dns sync DOMAIN
    claudedeck server cloudflare | zone add example.com
    claudedeck server ns set DOMAIN                # Namecheap nameservers to Cloudflare's
    claudedeck server static add SERVER example.com            # root static site, SSL, clean URLs
    claudedeck server domain add --static SERVER docs example.com [--target /opt/static/DIR] [--no-clean-urls]
    claudedeck server sync DOMAIN FOLDER           # upload FOLDER (inside a registered dir) to the site
    claudedeck server env rescan PROJECT [--dry-run]   # import keys new in .env.example
    ```

    ServerPlan v1.2 (same gating; new token scopes `sql`, `sql_write`, `local`):

    ```sh
    claudedeck server sql PROJECT "select * from users limit 5" [--local]   # read-only, a table
    claudedeck server sql PROJECT "update …" --write   # the user must approve (database name)
    claudedeck server db clone-for-local PROJECT [--target NAME] --wait   # dev copy; only the LOCAL env's DB_NAME changes
    claudedeck server local-env set PROJECT --from-file .env.local      # overrides only local runs see
    claudedeck server local run PROJECT [--port N] [--no-cache] --wait  # Docker on the panel's machine; prints the URL
    claudedeck server local logs PROJECT [--tail N] | local status PROJECT | local stop PROJECT
    claudedeck server git branches|pull PROJECT | refresh PROJECT | build PROJECT [--no-cache]
    claudedeck server git push PROJECT | git switch PROJECT BRANCH        # the user must approve
    claudedeck server pull-deploy PROJECT [--wait]   # git pull, then deploy (prints the deployment id)
    claudedeck server diagnose PROJECT               # checks; diagnose fix PROJECT ACTION (user approves)
    claudedeck server deploy-cancel DEPLOYMENT       # the user must approve
    claudedeck server domain set DOMAIN --port N | domain apply|nginx|purge DOMAIN
    claudedeck server cloudflare purge|ssl|ssl-full example.com
    claudedeck server pg databases|users SERVER | pg user-add SERVER USER PROJECT | pg grant SERVER USER DB [--revoke]
    claudedeck server pg clone SERVER DB TARGET [--project P]   # with --project: P's DEPLOY DB_NAME switches to TARGET
    claudedeck server server-env get|set SERVER …    # admin tokens only
    ```

    - Try a change locally first: `db clone-for-local`, `local run --wait`, `sql --local`, then deploy.
    - `sql` runs one statement. Never `--write` on the deploy database unless the user asked for it.

    - The port is the container's internal port (Traefik routes the domain to it). Only
      PostgreSQL databases; domains can't be bought here.
    - An existing database, domain or Dockerfile is an error (`conflict`), never overwritten.

    - `deploy` starts without asking (`--wait` streams the log; exit 0 success, 1 failed with the
      error and the log). Container stop/start/restart, replacing a DNS record and changing
      custom nameservers wait for the user's answer in ClaudeDeck (up to 2 minutes); exit 4 if
      they refuse. Don't retry a refusal.
    - Pass secrets with `env set --from-file` or stdin (`-`), never as `KEY=value` arguments.
    - `--json` passes ServerPlan's answer through.

    ## Exit codes

    | Code | Meaning |
    |---|---|
    | 0 | OK; for `wait`: the command exited 0, or the Claude session is idle |
    | 1 | `wait`: the command failed (its code is printed); otherwise an error |
    | 2 | Bad arguments, or not inside a ClaudeDeck session |
    | 3 | `wait`: the Claude session needs the user (permission or question) |
    | 4 | Refused: not allowed, the setting is off, a rate limit, or the user said no |
    | 5 | Unknown id, project, server or deployment |
    | 6 | `wait`: the Claude session stopped on its usage limit and waits for the reset |
    | 124 | `wait` timed out; the process is still running |

    ## Claude accounts and usage limits

    The owner may have several Claude accounts (Settings > Accounts). When a session hits its
    plan's usage limit, ClaudeDeck can end it and resume the same conversation (same session id,
    folder, options and pane) on another account, then type
    `[ClaudeDeck] Account switched after a usage limit. Continue exactly where you left off: ...`.
    Nothing to do for you except one habit: **keep your durable state in files** -
    `docs/AGENDA.md` (what's done, what's next) and `HANDOFF.md` for anything mid-flight - so a
    resumed session (or another one) can pick up from them.

    ```sh
    claudedeck account list [--json]          # name, 5h %, weekly %, limited, reset, priority, active/current
    claudedeck account current                # this session's account
    claudedeck account switch [--to NAME]     # move yourself now (you end and resume there)
    claudedeck new --account NAME|auto ...    # start a session on an account (auto: first with room)
    ```

    - In `list --json`, a Claude session at its limit has state `limit_reached` (and
      `limit_resets_at`), or `switching_account` while it moves. `wait` exits 6 only for
      `limit_reached`; a session that is moving keeps counting as running.
    - Don't `account switch` in a loop; if it says `no_account`, every account is at its limit and
      the session continues on its own when one resets.

    ## Rules

    - You can type only into terminals you opened (or plain terminals in a pane beside you).
    - Text you `send` to another Claude session becomes a note for the user unless the user allowed
      sessions to type into Claude; the output says `note` or `claude`. Don't retry to force it.
    - A terminal you opened can list, capture, wait and notify, but not open or send.
    - Panes sit side by side (at most four); `down` is placed like `right`. If there's no room, the
      terminal still starts and is listed in the sidebar (`"shown": false`).
    - Leave long-running terminals you opened for the user unless they ask you to stop them; stop a
      dev server with `claudedeck send ID $'\003'` (Ctrl+C) when you're done with it.

    ## Examples

    ```sh
    # Dev server beside you, then check it came up
    id=$(claudedeck open --name "web dev" -- npm run dev)
    sleep 5; claudedeck capture "$id" --lines 20 --trim

    # Tests in their own terminal; exit code tells finished / failed / timeout
    id=$(claudedeck open --split down -- swift test)
    claudedeck wait "$id" --timeout 900; echo "wait: $?"
    claudedeck capture "$id" --lines 40 --trim

    # Re-run in the same terminal
    claudedeck send "$id" "swift test --filter CartTests" --enter
    claudedeck wait "$id" --timeout 600

    # A second Claude session on another part of the work, then its result
    sid=$(claudedeck new --name "api tests" --worktree api-tests --prompt "Add tests for the cart API; commit them.")
    claudedeck wait "$sid" --timeout 1800; claudedeck capture "$sid" --lines 40 --trim
    ```

    ## How to ship a new service

    1. `claudedeck projects` - is it already a ClaudeDeck project?
    2. `claudedeck project add ~/Projects/new-api --create --group Services` - prints its id.
    3. `claudedeck new --project new-api --prompt "Scaffold the service: …"`, then
       `claudedeck wait ID` until it's done.
    4. `claudedeck server deploy new-api --wait` - exit 0 when it's live.
    5. `claudedeck server deploy-status DEPLOYMENT` later, or `server logs SERVER CONTAINER --tail 100`.

    ## New service on a server (ServerPlan v1.1)

    1. `claudedeck server dirs` - create the folder inside a registered dir
       (`claudedeck project add DIR/new-api --create`), then `claudedeck server scan DIR/new-api`:
       it prints the ServerPlan project.
    2. `claudedeck server ports SERVER` - build the service for its `suggested` port, then
       `claudedeck server project set PROJECT --server SERVER --port PORT`.
    3. `claudedeck server db create PROJECT` if it needs PostgreSQL.
    4. `claudedeck server env set PROJECT --from-file .env.production --secret API_KEY`.
    5. `claudedeck server domain add PROJECT api example.com` (the Cloudflare zone and A record
       are created automatically).
    6. For a fresh domain: `claudedeck server ns set api.example.com`.
    7. `claudedeck server deploy PROJECT --wait`.

    ## Static site (ServerPlan v1.1)

    No container: nginx serves the files (SSL and clean URLs on; the Cloudflare A record is
    created). None of these needs the user's approval.

    1. `claudedeck server static add SERVER example.com` for the root site, or
       `claudedeck server domain add --static SERVER docs example.com` for a subdomain
       (files in `/opt/static/docs-example-com` unless `--target` says otherwise).
    2. Build into a folder inside the project, e.g. `dist` (the project must be in a registered
       dir: `claudedeck server dirs`).
    3. `claudedeck server sync docs.example.com PROJECT/dist` - uploads it; run again after each build.
    4. For a fresh domain: `claudedeck server ns set docs.example.com`.
    """#
}
