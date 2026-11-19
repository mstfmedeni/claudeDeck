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

    Projects and sessions (Settings > Agents: "Sessions may add projects and start Claude sessions"):
      claudedeck projects [--json]
          The deck's projects: id, sessions, group, name, path.
      claudedeck project add PATH [--name NAME] [--group GROUP] [--create] [--json]
          Adds a folder as a project (an existing one: returns it). --create makes the folder,
          only under your home folder. Prints the project id.
      claudedeck new [--project ID|NAME|PATH] [--name NAME] [--prompt TEXT] [--worktree NAME] [--json]
          Starts a Claude session (in this session's project by default) and types TEXT once
          Claude is up. Prints the session id; wait, capture and send work on it.

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
          SERVER, PROJECT: an id or a name. Not every panel has every command: see server features.

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
      out=$(curl -sS -m "${max_time:-40}" -w '\n%{http_code} %header{x-claudedeck-exit} %header{x-claudedeck-next}' \
        -H "Authorization: Bearer $CLAUDEDECK_CLI_TOKEN" "$@" "$CLAUDEDECK_CLI_URL$path" 2>&1)
      status=$(printf '%s\n' "$out" | tail -n 1)
      body=$(printf '%s\n' "$out" | sed '$d')
      # "<http> <exit header> <next header>"; either header may be missing.
      set -- $status
      http=${1:-000}; code=${2:-}; next=${3:-}
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
              too_many_starts|too_many_projects|too_many_running) hint=" (rate limit or cap; try later)" ;;
              unknown_project) hint=" (see claudedeck projects)" ;;
              owner_refused) hint=" (the owner refused or didn't answer in ClaudeDeck)" ;;
              serverplan_off) hint=" (ServerPlan isn't set up in ClaudeDeck)" ;;
              not_available) hint="" ;;
              not_allowed) hint=" (this session's token doesn't allow that)" ;;
              not_yours) hint=" (only terminals this session opened, or ones beside it)" ;;
              unknown_session) hint=" (see claudedeck list)" ;;
              ambiguous) hint=" (give more of the id)" ;;
              not_running) hint=" (it isn't running)" ;;
              blocked) hint=" (a permission or a question is on screen)" ;;
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

    cmd_new() {
      project=self; name=""; prompt=""; worktree=""
      while [ $# -gt 0 ]; do
        case "$1" in
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
      case "$project" in
        /*|./*|../*) project=$(abs_path "$project") ;;
      esac
      ref=$(printf '%s' "$project" | sed 's/%/%25/g; s/\//%2F/g; s/ /%20/g; s/?/%3F/g; s/#/%23/g')
      need_session
      call "/projects/$ref/sessions" --data-urlencode "name=$name" --data-urlencode "prompt=$prompt" \
        --data-urlencode "worktree=$worktree" --data-urlencode "format=$(fmt)"
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

    cmd_server() {
      sub=${1:-}; [ $# -gt 0 ] && shift
      case "$sub" in
        ""|help) usage; exit 0 ;;
        env) cmd_server_env "$@"; return ;;
      esac
      p1=""; p2=""; p3=""; p4=""; n=0
      wait=0; follow=0; force=0; websocket=0; stdin=0; file=""; static=0; clean=1
      tail=""; server=""; sproject=""; sname=""; port=""; volume=""; dockerfile=""; target=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          --static) static=1 ;;
          --no-clean-urls) clean=0 ;;
          --wait) wait=1 ;;
          --follow|-f) follow=1 ;;
          --force) force=1 ;;
          --websocket) websocket=1 ;;
          --from-file) [ $# -ge 2 ] || die "server $sub: --from-file needs a file"; file=$2; shift ;;
          -) stdin=1 ;;
          --tail|--server|--project|--name|--port|--volume|--dockerfile|--target)
            [ $# -ge 2 ] || die "server $sub: $1 needs a value"
            case "$1" in
              --tail) tail=$2 ;; --server) server=$2 ;; --project) sproject=$2 ;; --name) sname=$2 ;;
              --port) port=$2 ;; --volume) volume=$2 ;; --dockerfile) dockerfile=$2 ;; --target) target=$2 ;;
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
        *) die "server: unknown command $sub (claudedeck help)" ;;
      esac
      case "$sub" in
        list|projects|dirs|features|cloudflare|deployments) args 0 "no arguments" ;;
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
        db) [ "$p1" = create ] || die "server db: try server db create PROJECT"; args 2 "db create PROJECT" ;;
        domain) case "$p1" in list) args 1 "domain list" ;;
          add) if [ "$static" = 1 ]; then args 4 "domain add --static SERVER SUBDOMAIN BASE"; else args 4 "domain add PROJECT SUBDOMAIN BASE"; fi ;;
          *) die "server domain: list, or add PROJECT SUBDOMAIN BASE" ;; esac ;;
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
        list|projects|dirs|features|cloudflare) srv "$sub" GET ;;
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
        db) srv db-create --data-urlencode "project=$p2" ;;
        domain)
          if [ "$p1" = list ]; then srv domain-list GET --data-urlencode "server=$server"
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

    # env set reads values from stdin (-) or a file so secrets stay out of the shell history;
    # values are never printed.
    cmd_server_env() {
      action=${1:-}; [ $# -gt 0 ] && shift
      case "$action" in get|set) ;; *) die "server env: get or set" ;; esac
      project=""; vars=""; secrets=""; file=""; stdin=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) json=1 ;;
          --from-file) [ $# -ge 2 ] || die "env set: --from-file needs a file"; file=$2; shift ;;
          --from-file=*) file=${1#*=} ;;
          --secret) [ $# -ge 2 ] || die "env set: --secret needs a key"; secrets="$secrets${secrets:+,}$2"; shift ;;
          --secret=*) secrets="$secrets${secrets:+,}${1#*=}" ;;
          -) stdin=1 ;;
          -*) die "env: unknown option $1" ;;
          *)
            if [ -z "$project" ]; then project=$1
            else
              case "$1" in *=*) vars="$vars$1
    " ;; *) die "env set: KEY=VALUE, not $1" ;; esac
            fi
            ;;
        esac
        shift
      done
      [ -n "$project" ] || die "env $action: which project?"
      if [ "$action" = get ]; then
        need_session
        srv env-get GET --data-urlencode "project=$project"
        finish
      fi
      if [ -n "$file" ]; then
        [ -r "$file" ] || die "env set: can't read $file"
        vars="$vars$(cat "$file")
    "
      fi
      if [ "$stdin" = 1 ]; then vars="$vars$(cat)
    "; fi
      [ -n "$vars" ] || die "env set: KEY=VALUE arguments, --from-file FILE, or - for stdin"
      need_session
      srv env-set --data-urlencode "project=$project" --data-urlencode "vars=$vars" --data-urlencode "secret=$secrets"
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
      projects) cmd_projects "$@" ;;
      project) cmd_project "$@" ;;
      new) cmd_new "$@" ;;
      server) cmd_server "$@" ;;
      *) usage >&2; exit 2 ;;
    esac
    """# + "\n"

    /// The Claude Code skill `claudedeck skill setup` installs (SKILL.md, without its hash line).
    public static let skill = #"""
    ---
    name: claudedeck
    description: Run and watch processes next to this ClaudeDeck session with the `claudedeck` command - open a terminal beside you for a dev server, a watcher or a long test run, type into it, read its screen, wait for it to finish, and notify or ask the user; add projects and start other Claude sessions; list, deploy and watch ServerPlan servers, containers and deployments. Use when the environment has CLAUDEDECK_SESSION set (you run inside ClaudeDeck) and a command should keep running or be visible to the user instead of blocking your Bash tool, or when work needs a new project, a parallel Claude session or a deploy.
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

    - `--create` makes the folder, only under the user's home folder.
    - `new` types `--prompt` once Claude is up. You may `send` to sessions you started, and
      `wait`/`capture` them like terminals.
    - Sessions you start don't stop at Claude Code's "do you trust this folder" question:
      ClaudeDeck trusts the folder first, if it's under the user's home (not a dot folder or
      ~/Library). Elsewhere the
      session waits for the user at that question: `capture` shows it; tell the user.
    - Limits: 5 new sessions per 10 minutes and 10 new projects per hour per session, 8
      started sessions running at once. Exit 4 (`too_many_…`) means wait; don't loop on it.
    - The user gets a notification for each and can see them in the activity log. Start
      sessions only when parallel work really helps, and say why in the prompt.

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
    ```

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
