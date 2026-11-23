#!/bin/sh
# Stand-in for `claude` in demo mode (tools/demo.sh). Prints the canned conversation for this
# terminal, reports its state the way the real hook would, then waits until the terminal closes.
DEMO="$(cd "$(dirname "$0")/.." && pwd)"
ID="$CLAUDEDECK_TERMINAL_ID"
SCENE="$DEMO/scenes/$ID"
ESC=$(printf '\033')

# Like Claude Code: a folder nobody trusted yet asks first, and nothing else (the hook included)
# happens until it's answered. Trust lives in the demo's home ($DEMO/home/.claude.json,
# projects[<folder>].hasTrustDialogAccepted; a folder above it counts too). Enter trusts it.
CONFIG="$DEMO/home/.claude.json"
# On another account (Settings › Accounts) its own config, as Claude Code does.
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && CONFIG="$CLAUDE_CONFIG_DIR/.claude.json"
trusted() {
  [ -f "$CONFIG" ] || return 0
  dir=$(pwd -P)
  while :; do
    jq -e --arg d "$dir" '.projects[$d].hasTrustDialogAccepted == true' "$CONFIG" >/dev/null 2>&1 && return 0
    [ "$dir" = / ] && return 1
    dir=$(dirname "$dir")
  done
}
if ! trusted; then
  printf '%s[1;33m Accessing workspace:%s[0m\n\n %s[1m%s%s[0m\n\n' "$ESC" "$ESC" "$ESC" "$(pwd -P)" "$ESC"
  printf " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.\n\n"
  printf " Claude Code'll be able to read, edit, and execute files here.\n\n"
  printf ' %s[36m❯ Yes, I trust this folder%s[0m\n   No, exit\n\n %s[2mEnter to confirm · Esc to cancel%s[0m\n' "$ESC" "$ESC" "$ESC" "$ESC"
  read -r _ || exit 0
  jq --arg d "$(pwd -P)" '.projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true})' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  printf '%s[2J%s[H' "$ESC" "$ESC"
fi

[ -f "$SCENE.txt" ] && sed "s/\[\([0-9;]*m\)/$ESC[\1/g" "$SCENE.txt"

TRANSCRIPT=""; [ -f "$SCENE.jsonl" ] && TRANSCRIPT="$SCENE.jsonl"
# Several Claude accounts: a session on another account runs with CLAUDE_CONFIG_DIR. A session
# without a scene gets a transcript too, so it can be resumed (moved to another account).
ACCOUNT="${CLAUDE_CONFIG_DIR:+$(basename "$CLAUDE_CONFIG_DIR")}"
if [ -z "$TRANSCRIPT" ]; then
  TRANSCRIPT="$SCENE.jsonl"
  [ -f "$TRANSCRIPT" ] || jq -nc '{type: "user", timestamp: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")), message: {role: "user", content: "hello"}}' > "$TRANSCRIPT"
fi
report() { # state, event, tool, detail
  jq -n --arg sid "demo-$ID" --arg tid "$ID" --argjson pid $$ --arg cwd "$PWD" --arg tp "$TRANSCRIPT" \
        --arg state "$1" --arg event "$2" --arg tool "$3" --arg detail "$4" \
        '{session_id: $sid, terminal_id: $tid, pid: $pid, cwd: $cwd,
          transcript_path: (if $tp == "" then null else $tp end),
          state: $state, event: $event, detail: $detail,
          tool_name: (if $tool == "" then null else $tool end), updated_at: now}' \
    > "$DEMO/sessions/.$ID.tmp" && mv "$DEMO/sessions/.$ID.tmp" "$DEMO/sessions/demo-$ID.json"
}

STATE=""
if [ -f "$SCENE.state" ]; then
  IFS='|' read -r STATE EVENT TOOL DETAIL < "$SCENE.state"
  sleep 1   # after the app has recorded the launch
  report "$STATE" "$EVENT" "$TOOL" "$DETAIL"
else
  # A session without a scene (claudedeck new): say how it was started, then wait at the
  # prompt like Claude Code does (idle), so `claudedeck wait` and the typed prompt have a target.
  printf 'demo claude, started with:'
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\naccount: %s\n\n> ' "${ACCOUNT:-default}"
  sleep 1
  report idle Stop "" ""
fi

# CLAUDEDECK_DEMO_LIVE=1 (tools/demo.sh creates $DEMO/live): every half minute or so the session
# moves on (working, a permission prompt, done, back to its scene) and its transcript gains a
# tool call, so the dashboard has something to follow.
STEP=0
TICK=0
PERIOD=$((20 + $(printf '%d' "0x$(printf '%s' "$ID" | tail -c 1)") * 3))
live() {
  [ -f "$DEMO/live" ] && [ -n "$STATE" ] || return 0
  TICK=$((TICK + 1))
  [ $TICK -ge $PERIOD ] || return 0
  TICK=0
  STEP=$((STEP + 1))
  case $((STEP % 5)) in
    1) report running PreToolUse Bash "Bash: npm test" ;;
    2) report running PostToolUse Edit "Edit: src/index.ts" ;;
    3) report needsPermission PermissionRequest Bash "Bash: git push origin HEAD" ;;
    4) report idle Stop "" "Done — pushed the branch." ;;
    0) report "$STATE" "$EVENT" "$TOOL" "$DETAIL" ;;
  esac
  if [ -n "$TRANSCRIPT" ]; then
    jq -nc --arg id "$ID-$STEP" '{type: "assistant", timestamp: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
      message: {id: "msg_live_\($id)", role: "assistant", content: [{type: "tool_use", id: "tu_live_\($id)", name: "Bash", input: {}}],
                usage: {output_tokens: 420}}}' >> "$TRANSCRIPT"
  fi
}

trap 'exit 0' HUP INT TERM

# Remote Control (RemoteControl.swift): $DEMO/scenes/<terminal id>.rc makes this session show up
# with Remote Control on, the way Claude Code's session registry has it
# ($DEMO/home/.claude/sessions/<pid>.json, "bridgeSessionId"). A typed `/remote-control` then
# draws its dialog, and Up Up Enter disconnects (the registry says null). Ctrl+C clears the
# prompt there instead of ending the session (Claude Code reads it as a key).
REGISTRY="$DEMO/home/.claude/sessions"
RC_DIALOG=""
rc_write() { # the bridge id as JSON, or null
  mkdir -p "$REGISTRY"
  jq -n --argjson pid $$ --arg sid "demo-$ID" --arg cwd "$PWD" --argjson bridge "$1" \
    '{pid: $pid, sessionId: $sid, cwd: $cwd, kind: "interactive", status: "idle",
      updatedAt: (now * 1000 | floor), bridgeSessionId: $bridge}' \
    > "$REGISTRY/.$$.tmp" && mv "$REGISTRY/.$$.tmp" "$REGISTRY/$$.json"
}
if [ -f "$SCENE.rc" ]; then
  rc_write '"session_demo"'
  trap '' INT
fi
rc_input() { # the line typed; true when it was for Remote Control
  [ -f "$SCENE.rc" ] || return 1
  case "$line" in
    */remote-control*)
      printf '\n Remote Control\n\n This session is available in the Claude mobile app and at https://claude.ai/code/session_demo.\n\n'
      printf '   Disconnect this session\n   Show QR code  Scan with your phone to open this session\n %s[36m❯ Continue%s[0m\n\n' "$ESC" "$ESC"
      printf ' %s[2mEnter to select · Esc to continue%s[0m\n' "$ESC" "$ESC"
      RC_DIALOG=1
      return 0 ;;
  esac
  [ -n "$RC_DIALOG" ] || return 1
  RC_DIALOG=""
  case "$line" in
    *"[A"*"[A"*|*OA*OA*)
      rm -f "$SCENE.rc"
      rc_write null
      printf '%s[2J%s[H  ⎿  Remote Control disconnected.\n\n> ' "$ESC" "$ESC" ;;
    *) printf '%s[2J%s[H> ' "$ESC" "$ESC" ;;
  esac
  return 0
}

# Load testing: while $DEMO/stream/<terminal id> (or $DEMO/stream/all) exists, redraw like Claude
# Code's fullscreen TUI (alternate screen, mouse tracking, synchronized output, a spinner in the
# title and on screen) about ten times a second.
#   mkdir -p /tmp/ClaudeDeckDemo/stream && touch /tmp/ClaudeDeckDemo/stream/all
streaming() { [ -f "$DEMO/stream/$ID" ] || [ -f "$DEMO/stream/all" ]; }
stream() {
  printf '%s[?1049h%s[?1000h%s[?1006h' "$ESC" "$ESC" "$ESC"
  n=0
  while streaming; do
    n=$((n + 1))
    case $((n % 4)) in 0) s='⠂' ;; 1) s='⠐' ;; 2) s='⠠' ;; *) s='⠄' ;; esac
    [ -f "$DEMO/stream/notitle" ] || printf '%s]0;%s Working on the cart%s' "$ESC" "$s" "$(printf '\007')"
    printf '%s[?2026h%s[H' "$ESC" "$ESC"
    i=1
    while [ $i -le 12 ]; do
      printf '%s[%d;1H%s[2K%s[2m%3d%s[0m  line %d of the transcript, frame %d' "$ESC" "$i" "$ESC" "$ESC" "$i" "$ESC" "$i" "$n"
      i=$((i + 1))
    done
    printf '%s[14;1H%s[2K%s[33m%s%s[0m Thinking… (%ds · esc to interrupt)' "$ESC" "$ESC" "$ESC" "$s" "$ESC" "$((n / 10))"
    printf '%s[16;3H%s[?2026l' "$ESC" "$ESC"
    sleep 0.1
  done
  printf '%s[?1006l%s[?1000l%s[?1049l' "$ESC" "$ESC" "$ESC"
}

# Testing `claudedeck` from a Claude session: $DEMO/scenes/<terminal id>.run is run once with this
# session's environment (as Claude's Bash tool would), its output in <terminal id>.run.out.
run_pending() {
  [ -f "$SCENE.run" ] || return 0
  mv "$SCENE.run" "$SCENE.running" && sh "$SCENE.running" > "$SCENE.run.out" 2>&1
  rm -f "$SCENE.running"
}

# Testing accounts: touching $DEMO/scenes/<terminal id>.limit makes the session stop on the usage
# limit as Claude Code does (the limit message in its transcript, then idle). Working at the time
# when $DEMO/scenes/<terminal id>.limit holds "busy" (it reports running first).
hit_limit() {
  [ -f "$SCENE.limit" ] || return 0
  how=$(cat "$SCENE.limit"); rm -f "$SCENE.limit"
  [ "$how" = busy ] && { report running UserPromptSubmit "" ""; sleep 1; }
  jq -nc --arg acct "${ACCOUNT:-default}" '{type: "assistant", isApiErrorMessage: true, timestamp: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
    message: {role: "assistant", content: [{type: "text", text: "You'\''ve hit your session limit · resets 11:50pm (demo account \($acct))"}]}}' >> "$TRANSCRIPT"
  printf '\n  ⎿  You'\''ve hit your session limit · resets 11:50pm\n\n> '
  report idle StopFailure "" ""
}

# A typed `/exit` ends it, as it ends Claude Code (restart, `claudedeck close`). Reading the
# terminal for a second stands in for the old `sleep 1`; without a terminal it just sleeps.
tick() {
  if [ -t 0 ]; then
    read -r -t 1 line 2>/dev/null
    rc=$?
    if [ "$rc" = 0 ]; then
      case "$line" in */exit*) exit 0 ;; esac
      rc_input || true
      return 0
    fi
    # Over 128: the second passed. Anything else (end of input): don't spin.
    [ "$rc" -gt 128 ] && return 0
  fi
  sleep 1 & wait $!
}

while :; do
  if streaming; then stream; else tick; live; run_pending; hit_limit; fi
done
