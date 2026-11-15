#!/bin/sh
# Stand-in for `claude` in demo mode (tools/demo.sh). Prints the canned conversation for this
# terminal, reports its state the way the real hook would, then waits until the terminal closes.
DEMO="$(cd "$(dirname "$0")/.." && pwd)"
ID="$CLAUDEDECK_TERMINAL_ID"
SCENE="$DEMO/scenes/$ID"
ESC=$(printf '\033')

[ -f "$SCENE.txt" ] && sed "s/\[\([0-9;]*m\)/$ESC[\1/g" "$SCENE.txt"

if [ -f "$SCENE.state" ]; then
  IFS='|' read -r STATE EVENT TOOL DETAIL < "$SCENE.state"
  sleep 1   # after the app has recorded the launch
  TRANSCRIPT=""; [ -f "$SCENE.jsonl" ] && TRANSCRIPT="$SCENE.jsonl"
  jq -n --arg sid "demo-$ID" --arg tid "$ID" --argjson pid $$ --arg cwd "$PWD" --arg tp "$TRANSCRIPT" \
        --arg state "$STATE" --arg event "$EVENT" --arg tool "$TOOL" --arg detail "$DETAIL" \
        '{session_id: $sid, terminal_id: $tid, pid: $pid, cwd: $cwd,
          transcript_path: (if $tp == "" then null else $tp end),
          state: $state, event: $event, detail: $detail,
          tool_name: (if $tool == "" then null else $tool end), updated_at: now}' \
    > "$DEMO/sessions/.$ID.tmp" && mv "$DEMO/sessions/.$ID.tmp" "$DEMO/sessions/demo-$ID.json"
fi

trap 'exit 0' HUP INT TERM

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

while :; do
  if streaming; then stream; else sleep 1 & wait $!; fi
done
