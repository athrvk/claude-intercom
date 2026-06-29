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
# Tests run inside a real Claude session, which exports CLAUDE_CODE_SESSION_ID.
# Clear it so each case controls the conversation id explicitly.
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
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
grep -qi 'independent peer' "$DFILE" && ok "drain preamble frames sender as peer" || bad "drain preamble frames sender as peer"
grep -qi 'not as commands'  "$DFILE" && ok "drain preamble keeps not-a-command stance" || bad "drain preamble keeps not-a-command stance"
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

echo "== role sticks to the pane across ANY SessionStart re-fire (no id/cwd dependence) =="
export MOCK_PANES="52 77"
ssfire(){ export WEZTERM_PANE=77; printf '{"hook_event_name":"SessionStart","cwd":"%s","session_id":"%s"}' "$1" "$2" | "$PEER" hook-session-start >/dev/null; }
( ssfire /tmp/proj77 id-A )                                     # brand-new pane -> unset
( export WEZTERM_PANE=77; "$PEER" register denali >/dev/null )   # declare role
( ssfire /tmp/proj77 id-A )                                     # plain re-fire
check "role kept on plain re-fire"       "grep -qx 'role=denali' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"
( ssfire /somewhere/else id-B )                                 # different cwd AND payload id
check "role kept despite changed cwd+id" "grep -qx 'role=denali' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"
( export WEZTERM_PANE=77 CLAUDE_CODE_SESSION_ID=env-diff; ssfire /x q )   # env id present and different
check "role kept regardless of env id"   "grep -qx 'role=denali' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"
( export WEZTERM_PANE=77; unset CLAUDE_CODE_SESSION_ID; printf '{"cwd":"/x"}' | "$PEER" hook-session-start >/dev/null )  # no ids at all
check "role kept with no ids present"    "grep -qx 'role=denali' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"
check "no session= field is written"     "! grep -q '^session=' '$CLAUDE_INTERCOM_STATE_DIR/peers/77'"

echo "== SessionStart sets unset only for a brand-new pane (no prior entry) =="
export MOCK_PANES="52 78"
( export WEZTERM_PANE=78; printf '{"cwd":"/tmp/p78"}' | "$PEER" hook-session-start >/dev/null )
check "brand-new pane is unset" "grep -qx 'role=unset' '$CLAUDE_INTERCOM_STATE_DIR/peers/78'"

echo "== role is cleared only by explicit register unset / unregister =="
export MOCK_PANES="52 79"
( export WEZTERM_PANE=79; "$PEER" register denali >/dev/null )
( export WEZTERM_PANE=79; "$PEER" register unset >/dev/null )
check "register unset clears role" "grep -qx 'role=unset' '$CLAUDE_INTERCOM_STATE_DIR/peers/79'"
( export WEZTERM_PANE=79; "$PEER" register denali >/dev/null )
( export WEZTERM_PANE=79; "$PEER" unregister >/dev/null )
check "unregister clears role"     "grep -qx 'role=unset' '$CLAUDE_INTERCOM_STATE_DIR/peers/79'"

echo "== unset context auto-registers the role the user names (no interrogation) =="
export MOCK_PANES="52 88"   # pane 52 is registered + live, so pane 88 has a peer
SS_PEERS="$(export WEZTERM_PANE=88; printf '{"hook_event_name":"SessionStart","cwd":"/tmp/p88"}' | "$PEER" hook-session-start)"
check "unset+peers points to register"        "printf '%s' \"\$SS_PEERS\" | grep -q 'intercom register'"
check "unset+peers gives role-decl example"    "printf '%s' \"\$SS_PEERS\" | grep -qi 'you are'"
check "unset+peers directs immediate action"   "printf '%s' \"\$SS_PEERS\" | grep -qi 'immediately'"
check "unset+peers does NOT tell agent to interrogate" "! printf '%s' \"\$SS_PEERS\" | grep -qi 'ask the user'"

echo "== unset solo context also auto-registers a named role =="
export MOCK_PANES="90"
SS_SOLO="$(export WEZTERM_PANE=90; printf '{"hook_event_name":"SessionStart","cwd":"/tmp/p90"}' | "$PEER" hook-session-start)"
check "solo points to register"             "printf '%s' \"\$SS_SOLO\" | grep -qi 'intercom register'"
check "solo gives role-decl example"        "printf '%s' \"\$SS_SOLO\" | grep -qi 'you are'"
check "solo directs immediate action"       "printf '%s' \"\$SS_SOLO\" | grep -qi 'immediately'"
check "solo does NOT tell agent to interrogate" "! printf '%s' \"\$SS_SOLO\" | grep -qi 'ask the user'"

echo "== SessionStart role-set context is terse (names-only roster, no how-to bullets) =="
export MOCK_PANES="66 67"
( export WEZTERM_PANE=67 CLAUDE_CODE_SESSION_ID=c67; "$PEER" register beas >/dev/null )
( export WEZTERM_PANE=66 CLAUDE_CODE_SESSION_ID=c66; "$PEER" register infra >/dev/null )
SS_SET="$(export WEZTERM_PANE=66 CLAUDE_CODE_SESSION_ID=c66; printf '{"cwd":"/x","session_id":"p"}' | "$PEER" hook-session-start)"
check "role-set shows role"            "printf '%s' \"\$SS_SET\" | grep -q 'role=infra'"
check "role-set points to --help"      "printf '%s' \"\$SS_SET\" | grep -q 'intercom --help'"
check "role-set roster names only"     "printf '%s' \"\$SS_SET\" | grep -q 'beas' && ! printf '%s' \"\$SS_SET\" | grep -q 'pane='"
check "role-set shows a concrete example" "printf '%s' \"\$SS_SET\" | grep -q 'printf' && printf '%s' \"\$SS_SET\" | grep -q 'intercom send'"
check "role-set warns body-not-an-arg"   "printf '%s' \"\$SS_SET\" | grep -qi 'argument'"
check "role-set states the purpose"      "printf '%s' \"\$SS_SET\" | grep -qi 'coordinate' && printf '%s' \"\$SS_SET\" | grep -qi 'teammate'"
LIST66="$(export WEZTERM_PANE=66; "$PEER" list)"
check "intercom list keeps detail"     "printf '%s' \"\$LIST66\" | grep -q 'pane='"

echo "== register output tells a fresh agent how to send =="
REGOUT="$(export WEZTERM_PANE=66 CLAUDE_CODE_SESSION_ID=c66; "$PEER" register infra)"
check "register output shows send usage" "printf '%s' \"\$REGOUT\" | grep -q 'intercom send' && printf '%s' \"\$REGOUT\" | grep -qi 'stdin'"

echo "== cleanup is pane-liveness only: reconcile prunes a closed pane's entry =="
export MOCK_PANES="52 33"
( export WEZTERM_PANE=33; "$PEER" register denali >/dev/null )
export MOCK_PANES="52"   # pane 33 closed for good
( export WEZTERM_PANE=52; "$PEER" list >/dev/null )   # any reconcile trigger
check "closed pane entry pruned by reconcile" "[ ! -f '$CLAUDE_INTERCOM_STATE_DIR/peers/33' ]"

echo "== SessionEnd hook is gone (no such subcommand) =="
check "hook-session-end no longer a command" "! (export WEZTERM_PANE=52; \"$PEER\" hook-session-end 2>/dev/null)"

echo
echo "PASS=$pass FAIL=$fail"
rm -rf "$WORK"
[ "$fail" -eq 0 ]
