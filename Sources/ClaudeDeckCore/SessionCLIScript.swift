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
    # 124 timeout (docs/agents.md in the ClaudeDeck repository).

    usage() {
      cat <<'EOF'
    claudedeck: work with ClaudeDeck from the session (or terminal) it started.

      claudedeck list [--json]
          Sessions and terminals, with their state; "self" is this one, "mine" ones it opened.
      claudedeck open [--split right|left|down|none] [--cwd DIR] [--name NAME] [--json] [--] [COMMAND...]
          A plain terminal next to this session running COMMAND; prints its id.
          One argument is a shell command line ("npm run dev"); several are run as given.
      claudedeck send ID TEXT [--enter] [--json]
          Types TEXT (- reads stdin) into a terminal this session opened or one beside it.
          Another Claude session gets it as a note unless the user lets sessions type into Claude.
      claudedeck capture ID [--lines N] [--trim] [--json]
          The screen and scrollback as text.
      claudedeck wait ID [--timeout SECONDS] [--json]
          Until the terminal's command finishes, or a Claude session is idle or needs the user.
      claudedeck notify TEXT
          A notification for the user.
      claudedeck ask [--agent NAME] QUESTION
          A question for the user, as a note beside this session (or for an agent you may ask).
      claudedeck skill setup [--user|--project] [--force]
          Installs the Claude Code skill that explains this command.

    ID: an id from `claudedeck list`, its first 8 characters, or "self".
    Exit codes: 0 ok/finished, 1 failed (or another error), 2 usage, 3 blocked (needs the user),
    4 refused, 5 unknown id, 124 timeout.
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
      case "$1" in *[!A-Za-z0-9-]*) die "$2: not an id: $1" ;; esac
    }

    # call PATH CURL-ARGS...: the answer's body in $body, its exit code in $code.
    call() {
      path=$1; shift
      out=$(curl -sS -m "${max_time:-40}" -w '\n%{http_code} %header{x-claudedeck-exit}' \
        -H "Authorization: Bearer $CLAUDEDECK_CLI_TOKEN" "$@" "$CLAUDEDECK_CLI_URL$path" 2>&1)
      status=$(printf '%s\n' "$out" | tail -n 1)
      body=$(printf '%s\n' "$out" | sed '$d')
      http=${status%% *}
      code=${status#* }
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
            case "$reason" in
              not_allowed) hint=" (this session's token doesn't allow that)" ;;
              not_yours) hint=" (only terminals this session opened, or ones beside it)" ;;
              unknown_session) hint=" (see claudedeck list)" ;;
              ambiguous) hint=" (give more of the id)" ;;
              not_running) hint=" (it isn't running)" ;;
              blocked) hint=" (a permission or a question is on screen)" ;;
              *) hint="" ;;
            esac
            printf 'claudedeck: %s%s (HTTP %s)\n' "${reason:-$body}" "$hint" "$http" >&2
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
      enter=0; id=""; text=""; have_text=0; options=1
      while [ $# -gt 0 ]; do
        case "$options:$1" in
          1:--enter) enter=1 ;;
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
      id=""; timeout=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --timeout) [ $# -ge 2 ] || die "wait: --timeout needs seconds"; timeout=$2; shift ;;
          --timeout=*) timeout=${1#*=} ;;
          --json) json=1 ;;
          -*) die "wait: unknown option $1" ;;
          *) [ -z "$id" ] || die "wait: one ID only"; id=$1 ;;
        esac
        shift
      done
      check_id "$id" wait
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
        call "/sessions/$id/wait" -G --data-urlencode "timeout=$window" --data-urlencode "format=$(fmt)"
        if [ "$code" = 124 ] && { [ "$timeout" -eq 0 ] || [ $((timeout - ($(date +%s) - start))) -gt 0 ]; }; then
          continue
        fi
        finish
      done
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
      notify) cmd_notify "$@" ;;
      ask) cmd_ask "$@" ;;
      skill) cmd_skill "$@" ;;
      *) usage >&2; exit 2 ;;
    esac
    """# + "\n"

    /// The Claude Code skill `claudedeck skill setup` installs (SKILL.md, without its hash line).
    public static let skill = #"""
    ---
    name: claudedeck
    description: Run and watch processes next to this ClaudeDeck session with the `claudedeck` command - open a terminal beside you for a dev server, a watcher or a long test run, type into it, read its screen, wait for it to finish, and notify or ask the user. Use when the environment has CLAUDEDECK_SESSION set (you run inside ClaudeDeck) and a command should keep running or be visible to the user instead of blocking your Bash tool.
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

    `ID` is a full id from `list`, its first 8 characters, or `self`. Add `--json` for
    machine-readable output.

    ## Exit codes

    | Code | Meaning |
    |---|---|
    | 0 | OK; for `wait`: the command exited 0, or the Claude session is idle |
    | 1 | `wait`: the command failed (its code is printed); otherwise an error |
    | 2 | Bad arguments, or not inside a ClaudeDeck session |
    | 3 | `wait`: the Claude session needs the user (permission or question) |
    | 4 | Refused: this session isn't allowed to do that |
    | 5 | Unknown id |
    | 124 | `wait` timed out; the process is still running |

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
    ```
    """#
}
