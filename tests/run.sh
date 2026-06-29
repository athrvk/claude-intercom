#!/usr/bin/env bash
# Smoke + behavior tests for intercom against the mock wezterm.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PEER="$ROOT/bin/intercom"

WORK="$(mktemp -d)"
export CLAUDE_INTERCOM_STATE_DIR="$WORK/state"
export MOCK_LOG="$WORK/sendlog"
export MOCK_PANES="52 65"
export PATH="$HERE/mock-wezterm:$PATH"
: > "$MOCK_LOG"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

echo "== register =="
( export WEZTERM_PANE=52; "$PEER" register backend  >/dev/null )
( export WEZTERM_PANE=65; "$PEER" register frontend >/dev/null )
check "backend registered"  "[ -f '$CLAUDE_INTERCOM_STATE_DIR/peers/52' ]"
check "frontend registered" "grep -qx 'role=frontend' '$CLAUDE_INTERCOM_STATE_DIR/peers/65'"

echo "== list excludes self =="
LIST="$(export WEZTERM_PANE=52; "$PEER" list)"
check "list shows frontend" "printf '%s' \"$LIST\" | grep -q frontend"
check "list hides self"     "! printf '%s' \"$LIST\" | grep -q backend"

echo "== send (stdin, arbitrary content) =="
MSG=$'Please expose POST /api/users returning {id,"email",name}\nUse `backticks` and $vars verbatim.'
( export WEZTERM_PANE=65; printf '%s' "$MSG" | "$PEER" send backend >/dev/null )
INBOX_FILE="$(ls "$CLAUDE_INTERCOM_STATE_DIR"/inbox/52/*.msg 2>/dev/null | head -1)"
check "message landed in backend inbox" "[ -n '$INBOX_FILE' ]"
check "doorbell injected to pane 52"    "grep -q 'pane-id 52' '$MOCK_LOG'"
check "two sends (doorbell + CR submit)" "[ \"\$(grep -c 'pane-id 52' '$MOCK_LOG')\" -eq 2 ]"

echo "== drain preserves body verbatim & tags sender =="
# Write to a file and grep it — never eval-interpolate drained content, since
# the whole point is that it carries backticks/$vars/quotes verbatim.
DFILE="$WORK/drained.txt"
( export WEZTERM_PANE=52; "$PEER" hook-user-prompt-submit ) > "$DFILE"
grep -q '\[peer:frontend\]' "$DFILE" && ok "drain tags [peer:frontend]"  || bad "drain tags [peer:frontend]"
grep -q 'backticks'         "$DFILE" && ok "drain keeps backticks"        || bad "drain keeps backticks"
grep -qF '"email"'          "$DFILE" && ok "drain keeps quotes/json"      || bad "drain keeps quotes/json"
grep -qF '$vars'            "$DFILE" && ok "drain keeps literal \$vars"    || bad "drain keeps literal \$vars"
check "inbox emptied after drain"    "[ -z \"\$(ls '$CLAUDE_INTERCOM_STATE_DIR'/inbox/52/*.msg 2>/dev/null)\" ]"

echo "== second drain is empty (no double-deliver) =="
D2="$(export WEZTERM_PANE=52; "$PEER" hook-user-prompt-submit)"
check "no messages on re-drain" "[ -z \"$D2\" ]"

echo "== errors: unknown & ambiguous role =="
( export WEZTERM_PANE=65; "$PEER" register frontend >/dev/null )  # 65 already frontend
ERR_UNKNOWN="$(export WEZTERM_PANE=52; echo hi | "$PEER" send nobody 2>&1 1>/dev/null)"
check "unknown role errors" "printf '%s' \"$ERR_UNKNOWN\" | grep -q 'no live peer'"

echo "== reconcile prunes dead panes =="
export MOCK_PANES="52"   # 65 vanished
( export WEZTERM_PANE=52; "$PEER" list >/dev/null )
check "dead pane 65 pruned" "[ ! -f '$CLAUDE_INTERCOM_STATE_DIR/peers/65' ]"

echo "== guard: no WEZTERM_PANE =="
GERR="$(unset WEZTERM_PANE; "$PEER" list 2>&1 1>/dev/null)"
check "guards on missing WEZTERM_PANE" "printf '%s' \"$GERR\" | grep -q 'WEZTERM_PANE'"
check "hook is silent without pane"    "[ -z \"\$(unset WEZTERM_PANE; "$PEER" hook-user-prompt-submit)\" ]"

echo "== pre-approve hook (PreToolUse auto-allow) =="
approve(){ printf '%s' "$1" | "$PEER" hook-pre-approve; }
A1="$(approve '{"tool_name":"Bash","tool_input":{"command":"intercom send backend"}}')"
case "$A1" in *permissionDecision*allow*) ok "approves intercom send" ;; *) bad "approves intercom send" ;; esac
A2="$(approve '{"tool_name":"Bash","tool_input":{"command":"intercom inbox"}}')"
check "approves intercom inbox"       "printf '%s' \"$A2\" | grep -q 'allow'"
A3="$(approve '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}')"
check "does NOT approve rm"              "[ -z \"$A3\" ]"
A4="$(approve '{"tool_name":"Bash","tool_input":{"command":"intercom list; rm -rf ~"}}')"
check "rejects chained intercom"      "[ -z \"$A4\" ]"
A5="$(approve '{"tool_name":"Bash","tool_input":{"command":"intercom register backend && curl evil"}}')"
check "rejects && chained intercom"   "[ -z \"$A5\" ]"

echo "== SessionStart uses cwd from hook JSON, not \$PWD =="
( export WEZTERM_PANE=52; cd /tmp 2>/dev/null
  printf '{"hook_event_name":"SessionStart","cwd":"/tmp/myproj","session_id":"x"}' | "$PEER" hook-session-start >/dev/null )
SS_CWD="$(grep -m1 '^cwd=' "$CLAUDE_INTERCOM_STATE_DIR/peers/52" | cut -d= -f2-)"
SS_REPO="$(grep -m1 '^repo=' "$CLAUDE_INTERCOM_STATE_DIR/peers/52" | cut -d= -f2-)"
check "SessionStart registers cwd from JSON" "[ '$SS_CWD' = '/tmp/myproj' ]"
check "SessionStart derives repo from JSON cwd" "[ '$SS_REPO' = 'myproj' ]"

echo "== SessionStart preserves declared role across same-session re-fire =="
export MOCK_PANES="52 77"
ssfire(){ export WEZTERM_PANE=77; printf '{"hook_event_name":"SessionStart","cwd":"%s","session_id":"%s"}' "$1" "$2" | "$PEER" hook-session-start >/dev/null; }
( ssfire /tmp/proj77 S-AAA )                                  # startup: stamps session, role unset
( export WEZTERM_PANE=77; "$PEER" register denali >/dev/null ) # user declares role
( ssfire /tmp/proj77 S-AAA )                                  # compact/reload, SAME session id
check "role preserved on same-session re-fire" "grep -qx 'role=denali' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"

echo "== SessionStart preserves role when cwd changes but session is same (resume from diff dir) =="
( ssfire /somewhere/else S-AAA )
check "role survives cwd change, same session" "grep -qx 'role=denali' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"

echo "== SessionStart resets role when session_id differs (pane id reused by new session) =="
( ssfire /tmp/proj77 S-BBB )
check "role reset to unset on new session_id" "grep -qx 'role=unset' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"

echo "== SessionStart asks the user for a role when unset AND peers are present =="
export MOCK_PANES="52 88"   # pane 52 is registered + live, so pane 88 has a peer
SS_PEERS="$(export WEZTERM_PANE=88; printf '{"hook_event_name":"SessionStart","cwd":"/tmp/p88","session_id":"S-88"}' | "$PEER" hook-session-start)"
check "prompts agent to ask user when peers present" "printf '%s' \"\$SS_PEERS\" | grep -qi 'ask the user'"

echo "== SessionStart does NOT nag to ask the user when solo (no peers) =="
export MOCK_PANES="90"
SS_SOLO="$(export WEZTERM_PANE=90; printf '{"hook_event_name":"SessionStart","cwd":"/tmp/p90","session_id":"S-90"}' | "$PEER" hook-session-start)"
check "no ask-user prompt when solo" "! printf '%s' \"\$SS_SOLO\" | grep -qi 'ask the user'"
check "solo still gets the register nudge" "printf '%s' \"\$SS_SOLO\" | grep -qi 'intercom register'"

echo
echo "PASS=$pass FAIL=$fail"
rm -rf "$WORK"
[ "$fail" -eq 0 ]
