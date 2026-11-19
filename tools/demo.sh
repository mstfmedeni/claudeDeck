#!/bin/sh
# Launches build/ClaudeDeck.app in demo mode with made-up projects and sessions, for screenshots.
#
#   ./build.sh && tools/demo.sh
#   tools/demo.sh -AppleLanguages '(tr)'     # same, with the Turkish UI
#
# Everything lives in $CLAUDEDECK_DEMO_ROOT (default /tmp/ClaudeDeckDemo) and is recreated on every run.
# CLAUDEDECK_DEMO_KEEP=1 relaunches on the existing demo data instead (sessions kept running by
# the demo's session helper reattach), e.g. after quitting the demo with the setting on.
# Demo mode never touches ~/.claude/settings.json, your deck.json or iCloud: sessions run
# tools/demo-claude.sh (a stand-in that prints a canned conversation and reports a fixed state)
# instead of the real `claude`.
#
# The agents' local API listens on $CLAUDEDECK_DEMO_AGENT_PORT (default 47832), never the real
# app's 47647; it and the command-line tool for sessions (claudedeck) are on with CLAUDEDECK_DEMO_CLI=1.
# CLAUDEDECK_DEMO_SHELL_COMMAND adds a terminal to acme-storefront that runs that command at launch
# (in the second pane).
#
# The demo turns the newer opt-in features on so they show (Simulators, Program Status on the
# payments-api dev server). CLAUDEDECK_DEMO_DEFAULTS=1 leaves every one of them at its default
# (off) instead: no Simulators, no Program Status, no claudedeck (CLAUDEDECK_DEMO_CLI is ignored)
# and no ServerPlan mock (CLAUDEDECK_SERVERPLAN_DEMO is ignored), as someone who just updated sees it.
set -eu
cd "$(dirname "$0")/.."

ROOT="${CLAUDEDECK_DEMO_ROOT:-/tmp/ClaudeDeckDemo}"
APP=build/ClaudeDeck.app
[ -d "$APP" ] || { echo "❌ $APP not found; run ./build.sh first" >&2; exit 1; }

launch() {
  echo "Demo data: $ROOT"
  CLAUDEDECK_DEMO=1 \
  CLAUDEDECK_DATA_DIR="$ROOT/data" \
  CLAUDEDECK_STATE_DIR="$ROOT/sessions" \
  CLAUDEDECK_CLAUDE_PATH="$ROOT/bin/claude" \
  CLAUDEDECK_GH_PATH="$ROOT/bin/gh" \
  CLAUDEDECK_CLAUDE_HOME="$ROOT/home" \
    "$APP/Contents/MacOS/ClaudeDeck" "$@" >/dev/null 2>&1 &
  echo "ClaudeDeck demo started (pid $!). Quit it with ⌘Q; run this script again for a fresh copy."
}

if [ -n "${CLAUDEDECK_DEMO_KEEP:-}" ] && [ -f "$ROOT/data/deck.json" ]; then
  # A ServerPlan mock the previous run started is still the demo's panel.
  if [ -f "$ROOT.serverplan.pid" ] && kill -0 "$(cat "$ROOT.serverplan.pid")" 2>/dev/null; then
    export CLAUDEDECK_SERVERPLAN_URL="http://127.0.0.1:${CLAUDEDECK_SERVERPLAN_PORT:-5099}" CLAUDEDECK_SERVERPLAN_TOKEN=spk_1_demo
  fi
  launch "$@"
  exit 0
fi

pkill -f "$ROOT/bin/claude" 2>/dev/null || true
# The demo's session helper (if the setting was on) and its sessions go with the old data.
pkill -f "claudedeck-ptyd --dir $ROOT/data" 2>/dev/null || true
rm -rf "$ROOT"
mkdir -p "$ROOT/bin" "$ROOT/scenes" "$ROOT/sessions" "$ROOT/data" "$ROOT/projects"
cp tools/demo-claude.sh "$ROOT/bin/claude"
chmod +x "$ROOT/bin/claude"

# --- Projects: small git repos with a little history and some uncommitted changes ------------------
repo() { # name, then "path|content" lines on stdin
  dir="$ROOT/projects/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Demo"
  git -C "$dir" config user.email "demo@example.com"
  while IFS='|' read -r path content; do
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$content" > "$dir/$path"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "Initial commit"
}

repo acme-storefront <<'EOF'
package.json|{ "name": "acme-storefront", "private": true, "scripts": { "dev": "next dev", "test": "vitest" } }
README.md|# Acme Storefront
src/cart/CartSummary.tsx|export function CartSummary() { return null }
src/cart/useCart.ts|export function useCart() { return { items: [] } }
src/checkout/Checkout.tsx|export function Checkout() { return null }
src/checkout/payment.ts|export async function pay() {}
src/app/page.tsx|export default function Page() { return null }
tests/checkout.test.ts|import { test } from "vitest"
EOF
D="$ROOT/projects/acme-storefront"
printf 'export function CartSummary({ items }) {\n  const total = items.reduce((s, i) => s + i.price * i.qty, 0)\n  return total\n}\n' > "$D/src/cart/CartSummary.tsx"
git -C "$D" commit -qam "Show cart total"
checkout() { # extra text ("" for none): $1 after the imports, $2 after the state, $3 + $4 in and after <CartSummary>
  cat <<TSX
import { useState } from "react"
import { useCart } from "../cart/useCart"
import { CartSummary } from "../cart/CartSummary"
import { pay } from "./payment"$1

type Status = "idle" | "paying" | "done" | "error"

export function Checkout() {
  const { items, clear } = useCart()
  const [status, setStatus] = useState<Status>("idle")
  const [error, setError] = useState<string | null>(null)$2

  async function submit() {
    setStatus("paying")
    try {
      await pay(items)
      clear()
      setStatus("done")
    } catch (e) {
      setError(e instanceof Error ? e.message : "Payment failed")
      setStatus("error")
    }
  }

  if (status === "done") {
    return <p className="checkout-done">Thanks! Your order is on its way.</p>
  }

  return (
    <section className="checkout">
      <h1>Checkout</h1>
      <CartSummary items={items}$3 />$4
      {error && <p role="alert">{error}</p>}
      <button disabled={status === "paying"} onClick={submit}>
        Pay now
      </button>
    </section>
  )
}
TSX
}
checkout '' '' '' '' > "$D/src/checkout/Checkout.tsx"
git -C "$D" commit -qam "Checkout page"
# docs/AGENDA.md: the project's Agenda Board (project menu › Agenda Board; the phone's Agenda).
mkdir -p "$D/docs"
cat > "$D/docs/AGENDA.md" <<'EOF'
# Agenda

| id | title | track | owner | status | depends-on | evidence |
|----|-------|-------|-------|--------|------------|----------|
| C1 | Cart total with quantities | cart | cart-agent | done | — | [PR #41](https://example.com/pr/41) |
| C2 | Coupon field (WELCOME10) | cart | cart-agent | doing | C1 | src/cart/coupons.ts |
| K1 | Checkout page | checkout | checkout-agent | done | — | tests/checkout.test.ts |
| K2 | Payment errors shown inline | checkout | checkout-agent | review | K1 | screenshot: checkout-error.png |
| K3 | Apple Pay button | checkout | | blocked | K2 | waiting on merchant id |
| P1 | Stripe webhooks retry with backoff | payments | api-agent | doing | | internal/webhooks/retry.go |
| P2 | Refund endpoint | payments | api-agent | todo | P1 | |
| R1 | Release 1.4 | release | owner | todo | C2, K2, P1 | |
EOF
git -C "$D" add docs/AGENDA.md
git -C "$D" commit -qm "Agenda"
printf 'export function CartSummary({ items, discount = 0 }) {\n  const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0)\n  return subtotal - discount\n}\n' > "$D/src/cart/CartSummary.tsx"
printf 'export function applyCoupon(code) { return code === "WELCOME10" ? 0.1 : 0 }\n' > "$D/src/cart/coupons.ts"
checkout '
import { CouponField } from "./CouponField"' '
  const [discount, setDiscount] = useState(0)' ' discount={discount}' '
      <CouponField onApply={setDiscount} />' > "$D/src/checkout/Checkout.tsx"
git -C "$D" add src/cart/coupons.ts

repo payments-api <<'EOF'
go.mod|module example.com/payments
main.go|package main
internal/webhooks/worker.go|package webhooks
internal/webhooks/retry.go|package webhooks
docker-compose.yml|services: {}
EOF
printf 'package webhooks\n\n// TODO: backoff\n' > "$ROOT/projects/payments-api/internal/webhooks/retry.go"
cat > "$ROOT/projects/payments-api/dev.sh" <<'EOF'
#!/bin/sh
# Demo stand-in for a dev server. Reports its state with OSC 7501 (Program Status): the terminal
# shows "Running", then "Needs input" until the migration question is answered.
status() { printf '\033]7501;state=%s%s\033\\' "$1" "${2:+:msg=$(printf '%s' "$2" | base64)}"; }
status working "Starting payments-db"
printf '\033[35mpayments-db \033[0m | database system is ready to accept connections\n'
status blocked "Apply 3 pending migrations?"
printf '\033[36mpayments-api\033[0m | 3 pending migrations. Apply them? [y/N] '
read -r answer
case "$answer" in y|Y) printf '\033[36mpayments-api\033[0m | migrations up to date (45)\n' ;; esac
status working "Listening on :8080"
printf '\033[36mpayments-api\033[0m | listening on http://localhost:8080\n'
printf '\033[36mpayments-api\033[0m | POST /v1/webhooks/stripe 200 12ms\n'
exec sleep 86400
EOF
chmod +x "$ROOT/projects/payments-api/dev.sh"
cat > "$ROOT/projects/payments-api/check.sh" <<'EOF'
#!/bin/sh
# Demo stand-in for a test run: reports "working", then "error" (OSC 7501) and exits 1.
printf '\033]7501;state=working:app=go:msg=%s\033\\' "$(printf 'Running 42 tests' | base64)"
printf 'ok   example.com/payments/internal/webhooks  0.41s\n'
sleep 2
printf -- '--- FAIL: TestRetryBackoff (0.02s)\n    retry_test.go:31: want 3 attempts, got 1\nFAIL\n'
printf '\033]7501;state=error:app=go:msg=%s\033\\' "$(printf '1 of 42 tests failed' | base64)"
exit 1
EOF
chmod +x "$ROOT/projects/payments-api/check.sh"

repo mobile-app <<'EOF'
Package.swift|// swift-tools-version: 6.0
Sources/Feed/FeedView.swift|import SwiftUI
Sources/Feed/FeedModel.swift|import Foundation
Tests/FeedTests/FeedTests.swift|import Testing
EOF

repo swift-markdown-kit <<'EOF'
Package.swift|// swift-tools-version: 6.0
Sources/MarkdownKit/Table.swift|struct Table {}
Sources/MarkdownKit/Parser.swift|struct Parser {}
EOF

repo blog <<'EOF'
astro.config.mjs|export default {}
src/posts/hello-world.md|# Hello
EOF

# --- Folder trust: the demo's own ~/.claude.json, never the real one. The projects above are
# trusted; a folder added later (claudedeck project add --create) makes the stand-in claude ask
# "Is this a project you created or one you trust?" unless ClaudeDeck trusted it first.
mkdir -p "$ROOT/home"
REAL_PROJECTS=$(cd "$ROOT/projects" && pwd -P)
for dir in "$REAL_PROJECTS"/*/; do printf '%s\n' "${dir%/}"; done \
  | jq -R . | jq -s '{numStartups: 3, projects: (map({key: ., value: {hasTrustDialogAccepted: true}}) | from_entries)}' \
  > "$ROOT/home/.claude.json"

# --- GitHub: a stand-in `gh` that answers from fixtures (made-up repositories and people) ----------
mkdir -p "$ROOT/github"
cat > "$ROOT/bin/gh" <<'EOF'
#!/bin/sh
# Demo stand-in for the GitHub CLI: answers `auth status`, `pr|issue view N`, `pr|issue list`,
# `repo view` and `run view --log-failed` from fixture files.
D="$(dirname "$0")/../github"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view"|"issue view") [ -f "$D/$1-$3.json" ] && exec cat "$D/$1-$3.json" ;;
  "repo view")
    case "$(basename "$PWD")" in
      acme-storefront) echo acme/storefront; exit 0 ;;
      payments-api) echo acme/payments-api; exit 0 ;;
    esac ;;
  "pr list"|"issue list")
    case " $* " in *" --head "*) ;; *)
      f="$D/$1-list.json"
      case " $* " in *"@me"*) f="$D/$1-list-me.json" ;; esac
      [ -f "$f" ] && exec cat "$f"
      echo "[]"; exit 0 ;;
    esac ;;
  "run view") [ -f "$D/run-log.txt" ] && exec cat "$D/run-log.txt" ;;
esac
echo "demo gh: no fixture for: $*" >&2
exit 1
EOF
chmod +x "$ROOT/bin/gh"
ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }   # ago 3H → ISO 8601, three hours ago

cat > "$ROOT/github/pr-42.json" <<EOF
{ "number": 42, "title": "Coupon codes in the cart", "state": "OPEN", "isDraft": false,
  "url": "https://github.com/acme/storefront/pull/42", "headRefName": "coupon-codes",
  "author": { "login": "alex" }, "updatedAt": "$(ago 25M)",
  "labels": [ { "name": "feature", "color": "1d76db" }, { "name": "checkout", "color": "fbca04" } ],
  "body": "Adds a **coupon field** to checkout and a \`discount\` prop to \`CartSummary\`.\n\n- \`WELCOME10\` takes 10% off\n- Invalid codes show an inline error\n\nCloses #37.",
  "reviewDecision": "CHANGES_REQUESTED", "mergeStateStatus": "BLOCKED",
  "comments": [
    { "id": "c1", "author": { "login": "alex" }, "body": "Screenshots of the new field are in the description of #37.", "createdAt": "$(ago 3H)" }
  ],
  "latestReviews": [
    { "author": { "login": "sam" }, "state": "CHANGES_REQUESTED", "submittedAt": "$(ago 40M)",
      "body": "Looks good overall. Coupon codes should be **case-insensitive**, and the e2e checkout test fails with a discount applied." }
  ],
  "statusCheckRollup": [
    { "__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "__typename": "CheckRun", "name": "unit tests", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "__typename": "CheckRun", "name": "e2e (chromium)", "workflowName": "CI", "status": "COMPLETED", "conclusion": "FAILURE",
      "detailsUrl": "https://github.com/acme/storefront/actions/runs/9001/job/9002" }
  ] }
EOF
cat > "$ROOT/github/issue-118.json" <<EOF
{ "number": 118, "title": "Webhook deliveries are lost when the receiver times out", "state": "OPEN",
  "url": "https://github.com/acme/payments-api/issues/118", "author": { "login": "jordan" },
  "updatedAt": "$(ago 2H)", "labels": [ { "name": "bug", "color": "d73a4a" } ],
  "body": "When a merchant endpoint takes longer than 10 s we drop the event. We should retry with backoff.",
  "comments": [] }
EOF
cat > "$ROOT/github/pr-7.json" <<EOF
{ "number": 7, "title": "Escaped pipes in table cells", "state": "MERGED", "isDraft": false,
  "url": "https://github.com/acme/swift-markdown-kit/pull/7", "headRefName": "fix-tables",
  "author": { "login": "casey" }, "updatedAt": "$(ago 1d)", "labels": [], "body": "Fixes #6.",
  "reviewDecision": "APPROVED", "comments": [], "latestReviews": [],
  "statusCheckRollup": [ { "__typename": "CheckRun", "name": "swift test", "status": "COMPLETED", "conclusion": "SUCCESS" } ] }
EOF
cat > "$ROOT/github/issue-list.json" <<EOF
[ { "number": 51, "title": "Cart total ignores shipping for EU addresses", "author": { "login": "jordan" },
    "labels": [ { "name": "bug", "color": "d73a4a" } ], "createdAt": "$(ago 2H)", "updatedAt": "$(ago 1H)",
    "url": "https://github.com/acme/storefront/issues/51" },
  { "number": 37, "title": "Coupon codes at checkout", "author": { "login": "sam" },
    "labels": [ { "name": "feature", "color": "1d76db" } ], "createdAt": "$(ago 3d)", "updatedAt": "$(ago 3H)",
    "url": "https://github.com/acme/storefront/issues/37" } ]
EOF
cat > "$ROOT/github/issue-list-me.json" <<EOF
[ { "number": 51, "title": "Cart total ignores shipping for EU addresses", "author": { "login": "jordan" },
    "labels": [ { "name": "bug", "color": "d73a4a" } ], "createdAt": "$(ago 2H)", "updatedAt": "$(ago 1H)",
    "url": "https://github.com/acme/storefront/issues/51" } ]
EOF
cat > "$ROOT/github/issue-51.json" <<EOF
{ "number": 51, "title": "Cart total ignores shipping for EU addresses", "state": "OPEN",
  "url": "https://github.com/acme/storefront/issues/51", "author": { "login": "jordan" },
  "updatedAt": "$(ago 1H)", "labels": [ { "name": "bug", "color": "d73a4a" } ],
  "body": "With a German address the cart shows the **subtotal** as the total. \`shippingFor(country:)\` returns 0 for EU codes.",
  "comments": [ { "id": "c51", "author": { "login": "alex" }, "body": "Reproduced with DE and FR.", "createdAt": "$(ago 1H)" } ] }
EOF
cat > "$ROOT/github/pr-list.json" <<EOF
[ { "number": 42, "title": "Coupon codes in the cart", "author": { "login": "alex" }, "isDraft": false,
    "labels": [ { "name": "feature", "color": "1d76db" } ], "createdAt": "$(ago 1d)", "updatedAt": "$(ago 25M)",
    "url": "https://github.com/acme/storefront/pull/42" } ]
EOF
printf 'e2e (chromium)\tRun tests\t2026-01-01T10:00:00.0000000Z FAIL checkout.spec.ts > applies WELCOME10\ne2e (chromium)\tRun tests\t2026-01-01T10:00:00.0000000Z Expected: 90.00  Received: 100.00\n' > "$ROOT/github/run-log.txt"

# --- deck.json ----------------------------------------------------------------------------------
G1=A0000000-0000-0000-0000-000000000001
G2=A0000000-0000-0000-0000-000000000002
P1=B0000000-0000-0000-0000-000000000001
P2=B0000000-0000-0000-0000-000000000002
P3=B0000000-0000-0000-0000-000000000003
P4=B0000000-0000-0000-0000-000000000004
P5=B0000000-0000-0000-0000-000000000005
S1=C0000000-0000-0000-0000-000000000001
S2=C0000000-0000-0000-0000-000000000002
S3=C0000000-0000-0000-0000-000000000003
S4=C0000000-0000-0000-0000-000000000004
S5=C0000000-0000-0000-0000-000000000005
S6=C0000000-0000-0000-0000-000000000006
S7=C0000000-0000-0000-0000-000000000007
S8=C0000000-0000-0000-0000-000000000008
NOW=$(date +%s)
P="$ROOT/projects"
DEFAULTS=false; [ "${CLAUDEDECK_DEMO_DEFAULTS:-}" = 1 ] && DEFAULTS=true
CLI=false; [ "${CLAUDEDECK_DEMO_CLI:-}" = 1 ] && [ "$DEFAULTS" = false ] && CLI=true
# CLAUDEDECK_DEMO_AUTONOMY=1 (with CLAUDEDECK_DEMO_CLI=1): sessions may add projects, start Claude
# sessions and use ServerPlan (claudedeck project add / new / server).
AUTONOMY=false; [ "$CLI" = true ] && [ "${CLAUDEDECK_DEMO_AUTONOMY:-}" = 1 ] && AUTONOMY=true
# CLAUDEDECK_DEMO_SIM_HOLDS=1 (with CLAUDEDECK_DEMO_CLI=1): sessions may reserve simulators
# (claudedeck sim; real simctl: it creates and boots "ClaudeDeck · …" simulators).
SIM_HOLDS=false; [ "$CLI" = true ] && [ "${CLAUDEDECK_DEMO_SIM_HOLDS:-}" = 1 ] && SIM_HOLDS=true
# CLAUDEDECK_DEMO_STALL=MINUTES[:notify|nudge|restart] (with CLAUDEDECK_DEMO_CLI=1): the stall watch on.
STALL_WATCH='{"enabled": false}'
if [ "$CLI" = true ] && [ -n "${CLAUDEDECK_DEMO_STALL:-}" ]; then
  STALL_WATCH=$(jq -cn --arg spec "$CLAUDEDECK_DEMO_STALL" \
    '($spec | split(":")) as $p | {enabled: true, minutes: ($p[0] | tonumber), action: ($p[1] // "notify")}')
fi
# Opt-in features, on unless CLAUDEDECK_DEMO_DEFAULTS=1.
if [ "$DEFAULTS" = true ]; then SIMULATORS=false; PROGRAM_STATUS=""; else SIMULATORS=true; PROGRAM_STATUS=', "showProgramStatus": true'; fi
EXTRA_SESSION=""
if [ -n "${CLAUDEDECK_DEMO_SHELL_COMMAND:-}" ]; then
  EXTRA_SESSION=$(jq -cn --arg id "$S8" --arg p "$P1" --arg c "$CLAUDEDECK_DEMO_SHELL_COMMAND" --argjson now "$NOW" \
    '{id: $id, projectID: $p, name: "acme-storefront · check", kind: "shell", createdAt: $now, isOpen: true, startupCommand: $c, autoStart: true}')
  EXTRA_SESSION=",
    $EXTRA_SESSION"
  PANES="\"$S1\", \"$S8\""
else
  PANES="\"$S1\", \"$S2\""
fi
# CLAUDEDECK_DEMO_PERSIST=1: start with "Keep sessions running when ClaudeDeck quits" on (ignored
# with CLAUDEDECK_DEMO_DEFAULTS=1, like the other opt-in features).
KEEP_SESSIONS=false; [ -n "${CLAUDEDECK_DEMO_PERSIST:-}" ] && [ "$DEFAULTS" = false ] && KEEP_SESSIONS=true
A1=D0000000-0000-0000-0000-000000000001
A2=D0000000-0000-0000-0000-000000000002
A3=D0000000-0000-0000-0000-000000000003
at() { date -v"$1" -v"$2"H -v"$3"M -v0S +%s; }   # at -1d 9 0 → yesterday 09:00
NEXT_WEEKDAY=$(n=1; while [ "$(date -v+${n}d +%u)" -gt 5 ]; do n=$((n + 1)); done; at +${n}d 9 0)
NEXT_MONDAY=$(date -v+1d -v+mon -v10H -v0M -v0S +%s)

cat > "$ROOT/data/deck.json" <<EOF
{
  "version": 1,
  "groups": [
    { "id": "$G1", "name": "Client Work", "collapsed": false, "colorIndex": 2 },
    { "id": "$G2", "name": "Open Source", "collapsed": false, "colorIndex": 4 }
  ],
  "projects": [
    { "id": "$P1", "path": "$P/acme-storefront", "name": "acme-storefront", "pinned": true, "collapsed": false },
    { "id": "$P2", "path": "$P/payments-api", "name": "payments-api", "groupID": "$G1", "pinned": false, "collapsed": false },
    { "id": "$P3", "path": "$P/mobile-app", "name": "mobile-app", "groupID": "$G1", "pinned": false, "collapsed": false },
    { "id": "$P4", "path": "$P/swift-markdown-kit", "name": "swift-markdown-kit", "groupID": "$G2", "pinned": false, "collapsed": false },
    { "id": "$P5", "path": "$P/blog", "name": "blog", "pinned": false, "collapsed": false }
  ],
  "sessions": [
    { "id": "$S1", "projectID": "$P1", "name": "acme-storefront", "kind": "claude", "createdAt": $NOW, "isOpen": true,
      "linkedWorkItem": { "kind": "pr", "repo": "acme/storefront", "number": 42 } },
    { "id": "$S2", "projectID": "$P1", "name": "acme-storefront · 2", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S3", "projectID": "$P2", "name": "payments-api", "kind": "claude", "createdAt": $NOW, "isOpen": true,
      "linkedWorkItem": { "kind": "issue", "repo": "acme/payments-api", "number": 118 } },
    { "id": "$S4", "projectID": "$P2", "name": "payments-api · ./dev.sh", "kind": "shell", "createdAt": $NOW, "isOpen": true,
      "startupCommand": "./dev.sh", "autoStart": true$PROGRAM_STATUS },
    { "id": "$S5", "projectID": "$P3", "name": "mobile-app", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S6", "projectID": "$P4", "name": "swift-markdown-kit · fix-tables", "kind": "claude", "createdAt": $NOW, "isOpen": true, "worktreeName": "fix-tables",
      "linkedWorkItem": { "kind": "pr", "repo": "acme/swift-markdown-kit", "number": 7 } },
    { "id": "$S7", "projectID": "$P5", "name": "blog", "kind": "claude", "createdAt": $NOW, "lastActivityAt": $((NOW - 7200)), "isOpen": false }$EXTRA_SESSION
  ],
  "selectedSessionID": "$S1",
  "panes": [ $PANES ],
  "automations": [
    { "id": "$A1", "name": "Test health", "projectID": "$P1", "workspace": "current", "reuseSession": false,
      "prompt": "Run the tests, lint and type checks. If anything is red, find the cause and fix what is safe to fix. Finish with a short summary of what you changed and what still needs a human.",
      "triggers": [ { "kind": "time", "schedule": "weekdays", "hour": 9, "minute": 0 } ],
      "enabled": true, "nextRunAt": $NEXT_WEEKDAY, "lastRunAt": $(at -1d 9 0), "lastRunStatus": "succeeded",
      "lastSessionID": "$S2", "createdAt": $((NOW - 864000)), "updatedAt": $((NOW - 864000)) },
    { "id": "$A2", "name": "Weekly changelog", "projectID": "$P2", "workspace": "newWorktree", "reuseSession": false,
      "prompt": "Summarize this week's commits into a changelog people can read, grouped by feature. Write it to CHANGELOG.md.",
      "triggers": [ { "kind": "time", "schedule": "weekly", "weekday": 2, "hour": 10, "minute": 0 } ],
      "enabled": true, "nextRunAt": $NEXT_MONDAY, "lastRunStatus": "succeeded", "createdAt": $((NOW - 1728000)) },
    { "id": "$A3", "name": "Audit dependencies", "projectID": "$P3", "workspace": "current", "reuseSession": false,
      "prompt": "Check Package.resolved for vulnerable, unused or unexpectedly upgraded packages.",
      "triggers": [ { "kind": "time", "schedule": "daily", "hour": 8, "minute": 30 } ],
      "enabled": false, "createdAt": $((NOW - 259200)) }
  ],
  "automationRuns": [
    { "id": "E0000000-0000-0000-0000-000000000001", "automationID": "$A1", "trigger": "scheduled", "scheduledFor": $(at -1d 9 0),
      "startedAt": $(at -1d 9 0), "completedAt": $(at -1d 9 6), "status": "succeeded", "sessionID": "$S2" },
    { "id": "E0000000-0000-0000-0000-000000000002", "automationID": "$A1", "trigger": "manual",
      "startedAt": $(at -2d 14 12), "completedAt": $(at -2d 14 19), "status": "succeeded" },
    { "id": "E0000000-0000-0000-0000-000000000003", "automationID": "$A1", "trigger": "scheduled", "scheduledFor": $(at -2d 9 0),
      "startedAt": $(at -2d 9 0), "completedAt": $(at -2d 9 30), "status": "failed", "error": "Timed out waiting for Claude to finish." },
    { "id": "E0000000-0000-0000-0000-000000000004", "automationID": "$A1", "trigger": "scheduled", "scheduledFor": $(at -3d 9 0),
      "startedAt": $(at -3d 11 42), "completedAt": $(at -3d 11 42), "status": "skipped", "error": "Missed the scheduled run beyond its grace period." },
    { "id": "E0000000-0000-0000-0000-000000000005", "automationID": "$A2", "trigger": "scheduled", "scheduledFor": $(at -2d 10 0),
      "startedAt": $(at -2d 10 0), "completedAt": $(at -2d 10 8), "status": "succeeded" }
  ],
  "settings": { "resumeOnLaunch": true, "compactOnResume": false, "notifications": true, "bounceDock": false, "confirmQuit": false,
                "pencilMCP": false, "terminalFontSize": 11,
                "agentAPIEnabled": $CLI, "agentAPIPort": ${CLAUDEDECK_DEMO_AGENT_PORT:-47832}, "sessionCLIEnabled": $CLI, "sessionsMayStartSessions": $AUTONOMY, "sessionsMayUseServerPlan": $AUTONOMY,
                "simulators": $SIMULATORS, "keepSessionsRunning": $KEEP_SESSIONS,
                "sessionsMayUseSimulators": $SIM_HOLDS, "stallWatch": $STALL_WATCH }
}
EOF

# --- Scenes: what each stand-in session prints, and the state it reports -----------------------
# <id>.state: state|event|tool_name|detail
scene() { printf '%s\n' "$2" > "$ROOT/scenes/$1.state"; cat > "$ROOT/scenes/$1.txt"; }

scene $S1 'needsPermission|PermissionRequest|Bash|Bash: pnpm vitest run tests/checkout.test.ts' <<'EOF'
[1m> [0mAdd coupon support to the cart summary and make sure checkout still passes.

[1m●[0m I'll add a [36mdiscount[0m prop to CartSummary and a small coupon helper.

[1m●[0m [1mUpdate[0m(src/cart/CartSummary.tsx)
  [2m⎿  Updated with 2 additions and 1 removal[0m
     [32m+ export function CartSummary({ items, discount = 0 }) {[0m
     [32m+   const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0)[0m
     [31m-   const total = items.reduce((s, i) => s + i.price * i.qty, 0)[0m

[1m●[0m [1mWrite[0m(src/cart/coupons.ts)
  [2m⎿  Wrote 1 line[0m

[1m●[0m Now let me run the checkout tests.

[33m╭──────────────────────────────────────────────────────────╮[0m
[33m│[0m [1mBash command[0m                                             [33m│[0m
[33m│[0m                                                          [33m│[0m
[33m│[0m   pnpm vitest run tests/checkout.test.ts                 [33m│[0m
[33m│[0m   [2mRun the checkout test suite[0m                            [33m│[0m
[33m│[0m                                                          [33m│[0m
[33m│[0m Do you want to proceed?                                  [33m│[0m
[33m│[0m [36m❯ 1. Yes[0m                                                 [33m│[0m
[33m│[0m   2. Yes, and don't ask again for [1mpnpm vitest[0m commands   [33m│[0m
[33m│[0m   3. No, and tell Claude what to do differently ([1mesc[0m)    [33m│[0m
[33m╰──────────────────────────────────────────────────────────╯[0m
EOF

scene $S2 'running|PostToolUse|Edit|Edit: src/checkout/Checkout.tsx' <<'EOF'
[1m> [0mMigrate the checkout page to the new design tokens.

[1m●[0m [1mRead[0m(src/checkout/Checkout.tsx)
  [2m⎿  Read 142 lines[0m

[1m●[0m [1mRead[0m(src/styles/tokens.ts)
  [2m⎿  Read 58 lines[0m

[1m●[0m The page still uses hard-coded colors in 9 places. Replacing them with tokens.

[1m●[0m [1mUpdate[0m(src/checkout/Checkout.tsx)
  [2m⎿  Updated with 9 additions and 9 removals[0m

[38;5;208m✻ Refactoring… [2m(34s · ↓ 1.2k tokens · esc to interrupt)[0m
EOF

scene $S3 'needsAnswer|PreToolUse|AskUserQuestion|Which retry strategy should the webhook worker use?' <<'EOF'
[1m> [0mMake webhook delivery retry on failures.

[1m●[0m [1mRead[0m(internal/webhooks/worker.go)
  [2m⎿  Read 211 lines[0m

[1m●[0m Before I change the worker, one decision:

[36m☐ Retry strategy[0m

[1mWhich retry strategy should the webhook worker use?[0m

[36m❯ 1. Exponential backoff[0m
     Up to 8 attempts over ~24h, with jitter
  2. Fixed interval
     Every 5 minutes, up to 12 attempts
  3. Dead-letter only
     No retries; failed events go to a queue for manual replay
EOF

scene $S5 'idle|Stop||Done — added pull-to-refresh to the feed and updated the snapshot tests.' <<'EOF'
[1m> [0mAdd pull-to-refresh to the feed screen.

[1m●[0m [1mUpdate[0m(Sources/Feed/FeedView.swift)
  [2m⎿  Updated with 6 additions[0m

[1m●[0m [1mUpdate[0m(Sources/Feed/FeedModel.swift)
  [2m⎿  Updated with 14 additions and 2 removals[0m

[1m●[0m [1mBash[0m(swift test)
  [2m⎿  ✔ Test run with 42 tests passed after 1.84 seconds.[0m

[1m●[0m Done — added pull-to-refresh to the feed and updated the snapshot tests.
  • [36mFeedView[0m uses [36m.refreshable[0m and shows the last-updated time
  • [36mFeedModel.reload()[0m is now async and cancels an in-flight load

[1m> [0m[7m [0m
EOF

scene $S6 'running|PreToolUse|Bash|Bash: swift test --filter TableTests' <<'EOF'
[1m> [0mTables with escaped pipes render as extra columns. Fix it.

[1m●[0m [1mRead[0m(Sources/MarkdownKit/Table.swift)
  [2m⎿  Read 96 lines[0m

[1m●[0m The cell splitter ignores backslash escapes. Adding a small scanner.

[1m●[0m [1mUpdate[0m(Sources/MarkdownKit/Table.swift)
  [2m⎿  Updated with 18 additions and 4 removals[0m

[1m●[0m [1mBash[0m(swift test --filter TableTests)
  [2m⎿  Running…[0m

[38;5;208m✻ Testing… [2m(12s · esc to interrupt)[0m
EOF

# --- A made-up ~/.claude for the Search and Skills tabs (never the real one) ------------------------
H="$ROOT/home/.claude"
transcript() { # project path, session id, prompt, reply
  d="$H/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$d"
  printf '{"type":"user","cwd":"%s","isSidechain":false,"timestamp":"2026-03-01T10:00:00.000Z","message":{"role":"user","content":"%s"}}\n{"type":"assistant","cwd":"%s","isSidechain":false,"timestamp":"2026-03-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' \
    "$1" "$3" "$1" "$4" > "$d/$2.jsonl"
}
transcript "$ROOT/projects/acme-storefront" 0e1d8a52-1111-4c2e-9a6b-5d0c2f7e9a01 \
  "Add a coupon field to the checkout and apply WELCOME10" "Added applyCoupon() in src/cart/coupons.ts and wired the coupon field into Checkout."
transcript "$ROOT/projects/acme-storefront" 0e1d8a52-2222-4c2e-9a6b-5d0c2f7e9a02 \
  "Why does the cart total ignore the discount?" "CartSummary summed the prices but never subtracted the coupon discount; fixed."
transcript "$ROOT/projects/payments-api" 0e1d8a52-3333-4c2e-9a6b-5d0c2f7e9a03 \
  "Validate coupon codes on the server too" "Added a coupon check to the refund and charge endpoints."
skill() { # dir, name, description
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n\n## Steps\n\n1. Read the relevant files.\n2. Make the change.\n\n```sh\nswift test\n```\n' "$2" "$3" "$2" > "$1/$2/SKILL.md"
}
skill "$H/skills" release-notes "Drafts release notes from the commits since the last tag."
skill "$H/skills" pr-review "Reviews the current branch like a careful teammate."
skill "$ROOT/projects/acme-storefront/.claude/skills" checkout-qa "Walks through the checkout flow and lists regressions."
# --- Agents inspector: a transcript with subagents for the first session (<id>.jsonl) ---------------
iso() { date -u -r $((NOW - $1)) +%Y-%m-%dT%H:%M:%S.000Z; }
asst() { printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-demo","role":"assistant","content":[%s]}}\n' "$(iso "$1")" "$2"; }
tool() { printf '{"type":"tool_use","id":"%s","name":"%s","input":%s}' "$1" "$2" "$3"; }
user() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":%s}%s}\n' "$(iso "$1")" "$2" "$3"; }
CART="$P/acme-storefront/lib/cart.ts"
SUB="$ROOT/scenes/$S1/subagents"
mkdir -p "$SUB"
{
  asst 1500 "$(tool m1 Read '{"file_path":"'"$P"'/acme-storefront/app/cart/page.tsx"}')"
  asst 1440 "$(tool t1 Agent '{"subagent_type":"Explore","description":"Map the checkout flow","prompt":"Find every place the checkout total is computed.","run_in_background":true}')"
  user 1439 '[{"type":"tool_result","tool_use_id":"t1","content":"launched"}]' ',"toolUseResult":{"status":"async_launched","agentId":"ademo1"}'
  asst 1430 "$(tool t2 Agent '{"subagent_type":"general-purpose","description":"Write cart tests","prompt":"Add tests for discounts and tax rounding.","run_in_background":true}')"
  user 1429 '[{"type":"tool_result","tool_use_id":"t2","content":"launched"}]' ',"toolUseResult":{"status":"async_launched","agentId":"ademo2"}'
  user 900 '"<task-notification><task-id>ademo1</task-id><tool-use-id>t1</tool-use-id><status>completed</status><usage><subagent_tokens>48210</subagent_tokens><tool_uses>23</tool_uses><duration_ms>539000</duration_ms></usage></task-notification>"' ''
  asst 880 "$(tool m2 Edit '{"file_path":"'"$CART"'"}')"
  # Edits inspector: Claude's file changes, with the patches Claude Code records for them.
  SUMMARY="$P/acme-storefront/src/cart/CartSummary.tsx"
  asst 700 "$(tool e1 Edit '{"file_path":"'"$SUMMARY"'","old_string":"items","new_string":"items, discount = 0"}')"
  user 699 '[{"type":"tool_result","tool_use_id":"e1","content":"ok"}]' ',"toolUseResult":{"type":"update","filePath":"'"$SUMMARY"'","originalFile":"export function CartSummary({ items }) {\n  const total = items.reduce((s, i) => s + i.price * i.qty, 0)\n  return total\n}\n","structuredPatch":[{"oldStart":1,"oldLines":4,"newStart":1,"newLines":4,"lines":["-export function CartSummary({ items }) {","-  const total = items.reduce((s, i) => s + i.price * i.qty, 0)","-  return total","+export function CartSummary({ items, discount = 0 }) {","+  const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0)","+  return subtotal - discount"," }"]}],"userModified":false}'
  COUPONS="$P/acme-storefront/src/cart/coupons.ts"
  asst 640 "$(tool e2 Write '{"file_path":"'"$COUPONS"'","content":"…"}')"
  user 639 '[{"type":"tool_result","tool_use_id":"e2","content":"ok"}]' ',"toolUseResult":{"type":"create","filePath":"'"$COUPONS"'","content":"const codes = { WELCOME10: 0.1, SPRING15: 0.15 }\n\nexport function applyCoupon(code) {\n  return codes[code.trim().toUpperCase()] ?? 0\n}\n","structuredPatch":[],"originalFile":null}'
  CHECKOUT="$P/acme-storefront/src/checkout/Checkout.tsx"
  asst 400 "$(tool e3 Edit '{"file_path":"'"$CHECKOUT"'","old_string":"<CartSummary items={items} />","new_string":"<CartSummary items={items} discount={discount} />"}')"
  user 399 '[{"type":"tool_result","tool_use_id":"e3","content":"ok"}]' ',"toolUseResult":{"type":"update","filePath":"'"$CHECKOUT"'","structuredPatch":[{"oldStart":9,"oldLines":4,"newStart":9,"newLines":5,"lines":["   const { items, clear } = useCart()","   const [status, setStatus] = useState<Status>(\"idle\")","   const [error, setError] = useState<string | null>(null)","+  const [discount, setDiscount] = useState(0)"," "]},{"oldStart":32,"oldLines":3,"newStart":33,"newLines":4,"lines":["       <h1>Checkout</h1>","-      <CartSummary items={items} />","+      <CartSummary items={items} discount={discount} />","+      <CouponField onApply={setDiscount} />","       {error && <p role=\"alert\">{error}</p>}"]}],"userModified":false}'
  asst 60 "$(tool m3 Bash '{"command":"npm test -- cart"}')"
} > "$ROOT/scenes/$S1.jsonl"
{
  asst 1435 "$(tool s1 Grep '{"pattern":"checkoutTotal"}')"
  asst 1300 "$(tool s2 Read '{"file_path":"'"$CART"'"}')"
  asst 1000 '{"type":"text","text":"done"}'
} > "$SUB/agent-ademo1.jsonl"
printf '{"agentType":"Explore","toolUseId":"t1"}' > "$SUB/agent-ademo1.meta.json"
{
  asst 1420 "$(tool s3 Read '{"file_path":"'"$CART"'"}')"
  asst 1200 "$(tool n1 Agent '{"subagent_type":"Explore","description":"Find tax helpers","prompt":"Where is tax rounding done?"}')"
  user 1080 '[{"type":"tool_result","tool_use_id":"n1","content":"ok"}]' ',"toolUseResult":{"status":"completed","agentId":"ademo3","totalTokens":9100,"totalToolUseCount":6,"totalDurationMs":120000}'
  asst 300 "$(tool s4 Write '{"file_path":"'"$P"'/acme-storefront/tests/cart.test.ts"}')"
  asst 20 "$(tool s5 Bash '{"command":"npx vitest run tests/cart.test.ts"}')"
} > "$SUB/agent-ademo2.jsonl"
printf '{"agentType":"general-purpose","toolUseId":"t2"}' > "$SUB/agent-ademo2.meta.json"

# --- Dashboard: a week of made-up transcript activity and today's state history ---------------------
# Transcripts (<id>.jsonl, reported by the stand-in claude): replies, prompts, tool calls with
# token counts and edits with patches, during working hours over the last seven days.
week() { # session id, seed, busyness 0-100, project dir, files…
  sid=$1 seed=$2 busy=$3 dir=$4; shift 4
  files=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -nc --argjson now "$NOW" --argjson seed "$seed" --argjson busy "$busy" --arg dir "$dir" --arg sid "$sid" --argjson files "$files" '
    def rnd($n): (($n * 1103515245 + 12345) % 2147483648);
    def ts($t): $t | strftime("%Y-%m-%dT%H:%M:%S.000Z");
    def tools: ["Read","Read","Grep","Edit","Edit","Bash","Bash","Read","Glob","Edit","Write","TodoWrite","Agent","WebFetch","mcp__github__get_pull_request"];
    range(0; 7 * 24 * 12) as $slot
    | ($now - 7 * 86400 + $slot * 300) as $t
    | ($t | localtime) as $lt | ($lt[3]) as $hour | ($lt[6]) as $wday
    | (rnd($slot * 7 + $seed * 7919) % 100) as $r
    | (rnd($slot * 13 + $seed * 31) % 1000) as $q
    | select($t < $now - 90)
    | select(($hour >= 9 and $hour < 12) or ($hour >= 13 and $hour < 18) or ($hour >= 20 and $hour < 23 and $r < 35) or ($t > $now - 7200))
    | select(($wday != 0 and $wday != 6) or $r < 20)
    | select($r < $busy)
    | (if $q % 7 == 0 then {type: "user", timestamp: ts($t), message: {role: "user", content: "Keep going with the next step."}} else empty end),
      {type: "assistant", timestamp: ts($t + 5), message: {id: "msg_\($sid)_\($slot)", role: "assistant", model: "claude-opus-demo",
        content: [{type: "text", text: "Working on it."}], usage: {output_tokens: (200 + $q * 3)}}},
      (range(0; 1 + $q % 4) as $k
       | (tools[(rnd($slot * 17 + $k * 101 + $seed) % (tools | length))]) as $tool
       | (if $tool == "Edit" or $tool == "Write" then "\($dir)/\($files[rnd($slot + $k * 3 + $seed) % ($files | length)])" else null end) as $path
       | {type: "assistant", timestamp: ts($t + 10 + $k * 20), message: {id: "msg_\($sid)_\($slot)_\($k)", role: "assistant", model: "claude-opus-demo",
           content: [{type: "tool_use", id: "tu_\($sid)_\($slot)_\($k)", name: $tool, input: (if $path then {file_path: $path} else {} end)}],
           usage: {output_tokens: (80 + rnd($slot + $k) % 900)}}},
         (if $path then
            (1 + rnd($slot * 3 + $k) % 14) as $plus | (rnd($slot * 5 + $k) % 6) as $minus
            | {type: "user", timestamp: ts($t + 12 + $k * 20), message: {role: "user", content: [{type: "tool_result", tool_use_id: "tu_\($sid)_\($slot)_\($k)", content: "ok"}]},
               toolUseResult: {type: "update", filePath: $path, userModified: false,
                 structuredPatch: [{oldStart: 10, oldLines: ($minus + 1), newStart: 10, newLines: ($plus + 1),
                   lines: ([" // context"] + [range(0; $minus) | "-  old line \(.)"] + [range(0; $plus) | "+  new line \(.)"])}]}}
          else empty end))
  ' > "$ROOT/scenes/$sid.jsonl"
}
week $S2 2 70 "$P/acme-storefront" src/checkout/Checkout.tsx src/app/page.tsx src/cart/useCart.ts tests/checkout.test.ts
week $S3 3 45 "$P/payments-api" internal/webhooks/worker.go internal/webhooks/retry.go main.go
week $S5 5 55 "$P/mobile-app" Sources/Feed/FeedView.swift Sources/Feed/FeedModel.swift Tests/FeedTests/FeedTests.swift
week $S6 6 35 "$P/swift-markdown-kit" Sources/MarkdownKit/Table.swift Sources/MarkdownKit/Parser.swift
# The ledger (dashboard.json): each session's working / waiting / idle stretches over the last
# 14 hours, and the plan's usage readings in the current 5-hour window, rising faster lately.
jq -n --argjson now "$NOW" \
  --arg s1 $S1 --arg s2 $S2 --arg s3 $S3 --arg s5 $S5 --arg s6 $S6 --arg s7 $S7 \
  --arg p1 $P1 --arg p2 $P2 --arg p3 $P3 --arg p4 $P4 --arg p5 $P5 '
  def rnd($n): (($n * 1103515245 + 12345) % 2147483648);
  def lane($s; $p; $k; $t; $i):
    if $t >= $now - 240 or $i > 80 then [] else
      (rnd($i * 31 + $k * 977)) as $r
      | ($t + (5 + $r % 22) * 60) as $worked
      | (($r / 7 | floor) % 6) as $mode
      | (if $mode == 0 then [{s: $s, p: $p, a: "permission", t: $worked}, {s: $s, p: $p, a: "running", t: ($worked + (1 + $r % 6) * 60)}]
         elif $mode == 1 then [{s: $s, p: $p, a: "question", t: $worked}] else [] end) as $wait
      | (if $mode == 0 then $worked + (4 + $r % 6) * 60 elif $mode == 1 then $worked + (2 + $r % 8) * 60 else $worked end) as $done
      | (if $i % 9 == 8 then "off" else "idle" end) as $rest
      | [{s: $s, p: $p, a: "running", t: $t}] + $wait + [{s: $s, p: $p, a: $rest, t: $done}]
        + lane($s; $p; $k; $done + (if $rest == "off" then 2400 else (2 + ($r / 13 | floor) % 25) * 60 end); $i + 1)
    end;
  def lanes: lane($s1; $p1; 1; $now - 50100; 0) + lane($s2; $p1; 2; $now - 46000; 0) + lane($s3; $p2; 3; $now - 40000; 0)
    + lane($s5; $p3; 5; $now - 30000; 0) + lane($s6; $p4; 6; $now - 21000; 0) + (lane($s7; $p5; 7; $now - 50000; 0) | map(select(.t < $now - 36000))) + [{s: $s7, p: $p5, a: "off", t: ($now - 36000)}];
  {
    events: [lanes[] | select(.t < $now - 30)],
    usage: [range(0; 17) as $i | ($now - 10200 + $i * 600) as $t | ($i / 17) as $x
            | {t: $t, h: (62 * pow($x; 1.6)), hr: ($now + 7800), w: (17.6 + 0.4 * $x), wr: ($now + 4 * 86400 + 6 * 3600)}],
    savedAt: $now
  }' > "$ROOT/data/dashboard.json"
# Opt-in: CLAUDEDECK_DEMO_LIVE=1 makes the stand-in sessions change state every so often.
if [ -n "${CLAUDEDECK_DEMO_LIVE:-}" ]; then touch "$ROOT/live"; fi

# --- ServerPlan: CLAUDEDECK_SERVERPLAN_DEMO=1 starts tools/serverplan-mock.py (made-up servers, a
# local /bin/sh as their terminals) on :5099 and points the demo at it. Or set CLAUDEDECK_SERVERPLAN_URL
# and CLAUDEDECK_SERVERPLAN_TOKEN yourself (demo mode only reads them).
if [ "$DEFAULTS" = true ]; then
  [ "${CLAUDEDECK_SERVERPLAN_DEMO:-}" = 1 ] && echo "CLAUDEDECK_DEMO_DEFAULTS=1: ServerPlan stays off (no mock)."
  unset CLAUDEDECK_SERVERPLAN_URL CLAUDEDECK_SERVERPLAN_TOKEN
elif [ "${CLAUDEDECK_SERVERPLAN_DEMO:-}" = 1 ]; then
  SP_PORT="${CLAUDEDECK_SERVERPLAN_PORT:-5099}"
  [ -f "$ROOT.serverplan.pid" ] && kill "$(cat "$ROOT.serverplan.pid")" 2>/dev/null || true
  python3 tools/serverplan-mock.py --port "$SP_PORT" --token spk_1_demo --root "$ROOT" --claude "$ROOT/bin/claude" \
    >"$ROOT/serverplan-mock.log" 2>&1 &
  echo $! > "$ROOT.serverplan.pid"
  export CLAUDEDECK_SERVERPLAN_URL="http://127.0.0.1:$SP_PORT" CLAUDEDECK_SERVERPLAN_TOKEN=spk_1_demo
  echo "ServerPlan mock on :$SP_PORT (pid $!); POST http://127.0.0.1:$SP_PORT/_demo/fail sends a failed deploy."
fi

launch "$@"
