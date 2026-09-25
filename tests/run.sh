#!/usr/bin/env bash
# End-to-end tests for the toolkit, all local: a throwaway "GitHub" origin,
# a bare repo made by git-deploy-new, real pushes through the shared hook,
# real signed deliveries through the real `webhook` daemon, a stub GitHub
# statuses API, and deploy.yml's own log-tailing loop run against a
# growing log. Nothing touches a real server or GitHub.
#
# Needs: bash, git, curl, openssl, jq, python3 with PyYAML, and
# adnanh/webhook (`apt install webhook python3-yaml jq`). Override the binaries with
# WEBHOOK_BIN=... / PYTHON=... (e.g. a venv's python that has pyyaml).
#
# Usage: tests/run.sh    (exit status = number of failed checks, capped)

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WEBHOOK_BIN="${WEBHOOK_BIN:-webhook}"
PYTHON="${PYTHON:-python3}"

for bin in git curl openssl jq "$PYTHON" "$WEBHOOK_BIN"; do
  command -v "$bin" > /dev/null || { echo "tests: missing $bin" >&2; exit 2; }
done
"$PYTHON" -c 'import yaml' 2> /dev/null || { echo "tests: $PYTHON lacks PyYAML" >&2; exit 2; }

T=$(mktemp -d)
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2> /dev/null || true; done
  if [[ -n "${KEEP_TMP:-}" ]]; then echo "tests: kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

# Isolate git from whoever runs this (their global config, identity, hooks).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

PASSED=0 FAILED=0
ok() { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
not_ok() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; [[ -z "${2:-}" ]] || sed 's/^/       | /' <<< "$2"; }
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else not_ok "$desc"; fi
}
section() { echo; echo "== $*"; }
free_port() { "$PYTHON" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
wait_until() { # wait_until <seconds> <command...>
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do (( $(date +%s) < deadline )) || return 1; sleep 0.1; done
}

section "syntax"
for f in share/post-receive share/git-deploy-webhook share/git-deploy-notify bin/git-deploy-new install.sh tests/run.sh; do
  check "bash -n $f" bash -n "$ROOT/$f"
done
check "hooks.json is valid JSON once templated" \
  "$PYTHON" -c 'import json,sys; json.loads(open(sys.argv[1]).read().replace("{{ getenv \"GIT_DEPLOY_WEBHOOK_SECRET\" }}","x"))' "$ROOT/share/webhook-hooks.json"
for f in "$ROOT"/template/*.yml.example; do
  check "$(basename "$f") is valid YAML" "$PYTHON" -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f"
done

# --- fixture ------------------------------------------------------------

cd "$T"
mkdir -p srv logs
git init -q --bare origin.git
git init -q -b main dev
(
  cd dev
  git commit -q --allow-empty -m initial
  # deploy_build exercises a $(...) whose inner failure is tolerated (must
  # NOT produce a "failed" line) and a guarded failure; deploy_restart fails
  # for real when FAILME exists, printing output that must stay private.
  cat > deploy.conf <<'EOF'
deploy_build() {
  local c; c=$(false; echo tolerated)
  if ! false; then echo "guarded failure tolerated"; fi
  echo "$newrev" >> "$WORKTREE/.deployed"
}
deploy_restart() {
  if [ -f FAILME ]; then sh -c 'cat private-output.txt; exit 3'; fi
  echo restarted
}
EOF
  echo "TOPSECRET-OUTPUT" > private-output.txt
  git add -A && git commit -q -m "add deploy.conf"
  git push -q ../origin.git main
  git checkout -q -b side && git commit -q --allow-empty -m side && git push -q ../origin.git side
  git checkout -q main
)
GIT_DEPLOY_LIB="$ROOT/share" GIT_DEPLOY_REPO_ROOT="$T/srv" \
  "$ROOT/bin/git-deploy-new" app "$T/www/app" > /dev/null
BARE="$T/srv/app.git" WORKTREE="$T/www/app"

commit() { # commit <message> [add|rm FAILME] -> prints new sha, pushed to origin
  (
    cd "$T/dev"
    case "${2:-}" in
      add) touch FAILME && git add FAILME ;;
      rm) git rm -q FAILME ;;
    esac
    git commit -q --allow-empty -m "$1"
    git push -q ../origin.git main
    git rev-parse HEAD
  )
}

# --- manual push through the shared hook ---------------------------------

section "manual git push deploy"
out=$(cd dev && git push "$BARE" main 2>&1)
MAIN1=$(git -C dev rev-parse main)
check "worktree checked out" test -f "$WORKTREE/deploy.conf"
check "deploy_build ran" grep -qx "$MAIN1" "$WORKTREE/.deployed"
check "deploy_restart ran" grep -q "remote: restarted" <<< "$out"
if grep -q "git-deploy: failed" <<< "$out"; then not_ok "tolerated failures print no 'failed' line" "$out"; else ok "tolerated failures print no 'failed' line"; fi
check "deploy.jsonl records success" bash -c "tail -1 '$BARE/deploy.jsonl' | grep -q '\"status\":\"success\"'"

FAIL1=$(commit "break restart" add)
out=$(cd dev && git push "$BARE" main 2>&1)
check "failing command is named" grep -q "git-deploy: failed (exit 3) in deploy_restart: sh -c 'cat private-output.txt; exit 3'" <<< "$out"
if grep -q "git-deploy: deployed" <<< "$out"; then not_ok "no 'deployed' line after a failure" "$out"; else ok "no 'deployed' line after a failure"; fi
check "deploy.jsonl records failure" bash -c "tail -1 '$BARE/deploy.jsonl' | grep -q '\"status\":\"failed\"'"

# --- webhook ------------------------------------------------------------

section "webhook deliveries"
printf 'GITHUB_REPO=Test/App\nGITHUB_URL=%s\n' "$T/origin.git" >> "$BARE/deploy.env"
API_PORT=$(free_port) HOOK_PORT=$(free_port)
: > statuses.txt
"$PYTHON" "$ROOT/tests/fake_github.py" "$API_PORT" "$T/statuses.txt" "$T/logs" & PIDS+=($!)
sed "s#/usr/local/lib/git-deploy/git-deploy-webhook#$ROOT/share/git-deploy-webhook#" \
  "$ROOT/share/webhook-hooks.json" > hooks.json
export GIT_DEPLOY_WEBHOOK_SECRET=test-secret GIT_DEPLOY_REPO_ROOT="$T/srv" \
  GIT_DEPLOY_GITHUB_TOKEN=test-token GIT_DEPLOY_GITHUB_API="http://127.0.0.1:$API_PORT" \
  GIT_DEPLOY_LOG_DIR="$T/logs" GIT_DEPLOY_LOG_BASE_URL="http://127.0.0.1:$API_PORT/logs/" \
  GIT_DEPLOY_WEBHOOK_NO_JOURNAL=1
"$WEBHOOK_BIN" -template -hooks hooks.json -ip 127.0.0.1 -port "$HOOK_PORT" -verbose > webhook.log 2>&1 & PIDS+=($!)
# Wait for both servers: an early status report racing the stub API's
# startup would otherwise fail (the script shrugs that off, the test can't).
wait_until 10 curl -s -o /dev/null "http://127.0.0.1:$API_PORT/" || { echo "tests: stub API didn't start" >&2; exit 2; }
wait_until 10 curl -s -o /dev/null "http://127.0.0.1:$HOOK_PORT/" || { cat webhook.log; exit 2; }

# Discord messages (git-deploy-notify) go to the stub too. The canary is the
# webhook's secret part, which must never show up anywhere but deploy.env.
DISCORD_URL="http://127.0.0.1:$API_PORT/discord/1/SECRET-canary"
echo "DISCORD_WEBHOOK_URL=$DISCORD_URL" >> "$BARE/deploy.env"
: > statuses.txt.discord
DMARK=0
dmark() { DMARK=$(wc -l < statuses.txt.discord); }
discord_new() { tail -n +$((DMARK + 1)) statuses.txt.discord; }
discord_titles() { discord_new | jq -r '.embeds[0].title' | tr '\n' '|'; }
# A webhook deploy's final GitHub status can land before its last Discord
# message: wait for the expected count, then a moment more so a duplicate
# would be counted too.
dwait() { wait_until 10 test "$(wc -l < statuses.txt.discord)" -ge $((DMARK + $1)) || true; sleep 0.5; }

send() { # send <id> <sha> [environment] [task] [secret] -> prints response body
  local body sig
  body=$(printf '{"action":"created","deployment":{"id":%s,"sha":"%s","environment":"%s","task":"%s"},"repository":{"full_name":"test/app"}}' \
    "$1" "$2" "${3:-production}" "${4:-git-deploy}")
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "${5:-test-secret}" -r | cut -d' ' -f1)
  curl -s -H 'Content-Type: application/json' -H 'X-GitHub-Event: deployment' \
    -H "X-Hub-Signature-256: sha256=$sig" -d "$body" "http://127.0.0.1:$HOOK_PORT/hooks/git-deploy"
}
statuses() { grep "/deployments/$1/statuses " statuses.txt || true; }
has_state() { statuses "$1" | grep -q "\"state\":\"$2\""; }
final() { # wait for a final status; a timeout is a failed check, not an abort
  wait_until 30 bash -c "grep '/deployments/$1/statuses ' '$T/statuses.txt' | grep -qE '\"state\":\"(success|failure|error)\"'" \
    || not_ok "deployment $1 reached a final status within 30s" "$(statuses "$1")"
}
public_log() { cat "$T"/logs/"$1"-*.log 2> /dev/null; }
settle() { sleep 1.5; } # for deliveries that should produce nothing at all

# Bare repo is currently at FAIL1 from the manual push; fix it on GitHub.
MAIN2=$(commit "fix restart" rm)
dmark
send 100 "$MAIN2" > /dev/null; final 100
dwait 2
check "discord: started + finished, once each" test "$(discord_titles)" = "🚀 Deploy started: App → production|✅ Deploy succeeded: App → production|"
check "discord: names the trigger and links the log" bash -c "tail -1 '$T/statuses.txt.discord' | jq -e '.embeds[0].fields | (map(select(.value == \"Deploy button\")) | length == 1) and (map(select(.name == \"Log\" and (.value | contains(\"/logs/100-\")))) | length == 1)' > /dev/null"
check "discord: start message lists the new commit" bash -c "head -$((DMARK + 1)) '$T/statuses.txt.discord' | tail -1 | jq -r '.embeds[0].description' | grep -q '• fix restart'"
check "valid delivery -> in_progress" has_state 100 in_progress
check "valid delivery -> success" has_state 100 success
check "status links the log" bash -c "grep '/deployments/100/' '$T/statuses.txt' | grep -q '\"log_url\":\"http://127.0.0.1:$API_PORT/logs/100-'"
check "deployed the requested commit" test "$(git -C "$BARE" rev-parse main)" = "$MAIN2"
check "deploy_build ran for it" grep -qx "$MAIN2" "$WORKTREE/.deployed"
if grep -rq "$T" logs/; then not_ok "public log masks server paths" "$(public_log 100)"; else ok "public log masks server paths"; fi
check "public log shows progress" grep -q "git-deploy: running deploy_restart" <(public_log 100)
check "every public log line is timestamped" bash -c "! grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4} git-deploy' <(cat '$T'/logs/100-*.log)"

dmark
send 100 "$MAIN2" > /dev/null; settle
check "replayed id is ignored" test "$(statuses 100 | wc -l)" -eq 2
check "... and not announced" test -z "$(discord_new)"
send 99 "$MAIN2" > /dev/null; settle
check "older id is ignored" test -z "$(statuses 99)"
check "wrong signature is rejected" grep -q "Error occurred while evaluating hook rules" <(send 101 "$MAIN2" production git-deploy wrong-secret)
check "wrong task is not run" grep -q "Hook rules were not satisfied" <(send 102 "$MAIN2" production deploy)
settle
check "... and neither reports anything" test -z "$(statuses 101)$(statuses 102)"

SIDE=$(git -C dev rev-parse side)
dmark
send 103 "$SIDE" > /dev/null; final 103
dwait 1
check "discord: failure before the hook ran -> one failed message" test "$(discord_titles)" = "❌ Deploy failed: App → production|"
check "commit not on main -> failure" bash -c "grep '/deployments/103/' '$T/statuses.txt' | grep -q 'is not on main'"
check "... and nothing deployed" test "$(git -C "$BARE" rev-parse main)" = "$MAIN2"

send 104 "$MAIN2" staging > /dev/null; final 104
check "unknown environment -> error" has_state 104 error

FAIL2=$(commit "break restart again" add)
dmark
send 105 "$FAIL2" > /dev/null; final 105
dwait 2
check "discord: failing deploy.conf -> started + failed" test "$(discord_titles)" = "🚀 Deploy started: App → production|❌ Deploy failed: App → production|"
check "failing deploy.conf -> failure" has_state 105 failure
check "public log names the failed command" grep -q "git-deploy: failed (exit 3) in deploy_restart: sh -c 'cat private-output.txt; exit 3'" <(public_log 105)
if public_log 105 | grep -q TOPSECRET; then not_ok "public log omits command output" "$(public_log 105)"; else ok "public log omits command output"; fi
check "full output still reaches stdout (journal)" grep -q TOPSECRET-OUTPUT webhook.log

MAIN3=$(commit "fix again" rm)
send 106 "$MAIN3" > /dev/null; final 106
send 107 "$MAIN3" > /dev/null; final 107
check "same-commit redeploy runs the hook again" test "$(grep -cx "$MAIN3" "$WORKTREE/.deployed")" -eq 2
send 108 "$MAIN1" > /dev/null; final 108
check "older commit on main can be redeployed (rollback)" test "$(git -C "$BARE" rev-parse main)" = "$MAIN1"

section "several environments of one repo"
GIT_DEPLOY_LIB="$ROOT/share" GIT_DEPLOY_REPO_ROOT="$T/srv" \
  "$ROOT/bin/git-deploy-new" app-beta "$T/www/app-beta" > /dev/null
printf 'GITHUB_REPO=Test/App\nGITHUB_URL=%s\nGITHUB_ENVIRONMENT=beta\n' "$T/origin.git" >> "$T/srv/app-beta.git/deploy.env"
PROD_BEFORE=$(git -C "$BARE" rev-parse main)
echo "DISCORD_WEBHOOK_URL=$DISCORD_URL" >> "$T/srv/app-beta.git/deploy.env"
dmark
send 120 "$MAIN3" beta > /dev/null; final 120
dwait 2
check "discord: names the environment" test "$(discord_titles)" = "🚀 Deploy started: App → beta|✅ Deploy succeeded: App → beta|"
check "environment picks the matching bare repo" test "$(git -C "$T/srv/app-beta.git" rev-parse main 2> /dev/null)" = "$MAIN3"
check "... and deploys its own worktree" grep -qx "$MAIN3" "$T/www/app-beta/.deployed"
check "... without touching production" test "$(git -C "$BARE" rev-parse main)" = "$PROD_BEFORE"
check "deploy ids are tracked per environment" test "$(cat "$T/srv/app-beta.git/git-deploy-webhook.last-id")" = 120
GIT_DEPLOY_LIB="$ROOT/share" GIT_DEPLOY_REPO_ROOT="$T/srv" \
  "$ROOT/bin/git-deploy-new" app-beta2 "$T/www/app-beta2" > /dev/null
printf 'GITHUB_REPO=test/app\nGITHUB_ENVIRONMENT=beta\n' >> "$T/srv/app-beta2.git/deploy.env"
send 121 "$MAIN3" beta > /dev/null; final 121
check "two bare repos claiming one environment -> error" has_state 121 error
rm -rf "$T/srv/app-beta2.git"

# A failure nobody anticipated (here: a read-only ref store) after
# in_progress must still end in a final status, not "in progress" forever.
chmod a-w "$BARE/refs/heads"
dmark
send 110 "$MAIN3" > /dev/null; final 110
chmod u+w "$BARE/refs/heads"
dwait 1
check "unexpected abort -> error status" has_state 110 error
check "discord: unexpected abort -> one failed message" test "$(discord_titles)" = "❌ Deploy failed: App → production|"

section "GIT_DEPLOY_LOG_PUBLIC=full"
GIT_DEPLOY_LOG_PUBLIC=full "$ROOT/share/git-deploy-webhook" test/app 111 "$FAIL2" production > /dev/null 2>&1 || true
check "full mode publishes command output" grep -q TOPSECRET-OUTPUT <(public_log 111)

# --- manual pushes recorded as GitHub Deployments (push mode) -----------

section "manual push to an opted-in app"
check "webhook deliveries never create deployments themselves" bash -c "! grep -q '/deployments {' '$T/statuses.txt'"
# Push mode reads the server's env file itself; prove it by giving it the
# settings only through that file.
cat > push.env <<EOF
GIT_DEPLOY_GITHUB_TOKEN=test-token
GIT_DEPLOY_GITHUB_API=http://127.0.0.1:$API_PORT
GIT_DEPLOY_LOG_DIR=$T/logs
GIT_DEPLOY_LOG_BASE_URL=http://127.0.0.1:$API_PORT/logs/
EOF
manual_push() { # manual_push <env file> -> pusher's output
  (cd dev && env -u GIT_DEPLOY_GITHUB_TOKEN -u GIT_DEPLOY_GITHUB_API -u GIT_DEPLOY_LOG_DIR -u GIT_DEPLOY_LOG_BASE_URL \
    GIT_DEPLOY_ENV_FILE="$1" git push "$BARE" main 2>&1)
}
created() { grep '/deployments {' statuses.txt | grep -c "\"ref\":\"$1\"" || true; }

PUSH1=$(commit "manual push")
dmark
out=$(manual_push "$T/push.env")
echo "$out" >> all-push-output.txt
check "discord: started + finished, once each (no double via hand-off)" test "$(discord_titles)" = "🚀 Deploy started: App → production|✅ Deploy succeeded: App → production|"
check "discord: trigger is git push, log linked" bash -c "tail -1 '$T/statuses.txt.discord' | jq -e '.embeds[0].fields | (map(select(.value == \"git push\")) | length == 1) and (map(select(.name == \"Log\")) | length == 1)' > /dev/null"
check "creates a deployment for the pushed commit" test "$(created "$PUSH1")" -eq 1
check "... with task git-deploy-push (which the webhook ignores)" bash -c "grep '/deployments {' '$T/statuses.txt' | grep '$PUSH1' | grep -q '\"task\":\"git-deploy-push\"'"
check "... in the app's environment" bash -c "grep '/deployments {' '$T/statuses.txt' | grep '$PUSH1' | grep -q '\"environment\":\"production\"'"
check "reports in_progress then success" bash -c "grep -q '/deployments/5000/statuses .*in_progress' '$T/statuses.txt' && grep -q '/deployments/5000/statuses .*success' '$T/statuses.txt'"
check "links a public log" grep -q "git-deploy: running deploy_restart" <(public_log 5000)
check "pusher still sees the full output" grep -q "remote: restarted" <<< "$out"
check "deploys exactly once (no hand-off loop)" test "$(grep -cx "$PUSH1" "$WORKTREE/.deployed")" -eq 1
check "advances the replay guard" test "$(cat "$BARE/git-deploy-webhook.last-id")" = 5000

PUSH2=$(commit "not on GitHub yet")
echo "$PUSH2" >> statuses.txt.unknown-refs
out=$(manual_push "$T/push.env")
check "commit GitHub lacks -> says so" grep -q "doesn't have ${PUSH2:0:12}" <<< "$out"
check "... and still deploys" grep -qx "$PUSH2" "$WORKTREE/.deployed"

PUSH_OWNER=$(commit "owner-specific token")
{ cat push.env; echo "GIT_DEPLOY_GITHUB_TOKEN_TEST=owner-token"; } > push-owner.env
manual_push "$T/push-owner.env" > /dev/null
check "owner-specific token wins over the default" bash -c "grep '/deployments {' '$T/statuses.txt' | grep '$PUSH_OWNER' | grep -q 'auth=owner-token\$'"

PUSH_DOWN=$(commit "GitHub unreachable")
sed "s#^GIT_DEPLOY_GITHUB_API=.*#GIT_DEPLOY_GITHUB_API=http://127.0.0.1:$(free_port)#" push.env > push-down.env
out=$(manual_push "$T/push-down.env")
check "GitHub unreachable -> says so" grep -q "GitHub API unreachable" <<< "$out"
check "... and still deploys" grep -qx "$PUSH_DOWN" "$WORKTREE/.deployed"

PUSH3=$(commit "no token")
grep -v TOKEN push.env > push-notoken.env
dmark
out=$(manual_push "$T/push-notoken.env")
echo "$out" >> all-push-output.txt
check "discord: unrecorded push still announced once" test "$(discord_titles)" = "🚀 Deploy started: App → production|✅ Deploy succeeded: App → production|"
check "no token -> says so" grep -q "no GitHub token configured" <<< "$out"
check "... and still deploys" grep -qx "$PUSH3" "$WORKTREE/.deployed"

PUSH4=$(commit "break it manually" add)
out=$(manual_push "$T/push.env")
check "failing manual push -> failure status" bash -c "grep -qE '/deployments/50[0-9]{2}/statuses .*\"failure\"' '$T/statuses.txt'"
check "... and the pusher sees the failed command" grep -q "git-deploy: failed (exit 3) in deploy_restart" <<< "$out"
commit "unbreak" rm > /dev/null

section "discord notifications"
TRICKY=$(commit $'quote " back\\slash\ttab @everyone')
dmark
out=$(manual_push "$T/push.env"); echo "$out" >> all-push-output.txt
check "odd commit subjects still make valid JSON" test "$(discord_new | jq -c . 2> /dev/null | wc -l)" -eq 2
check "... with the subject intact" grep -qF $'• quote " back\\slash\ttab @everyone' <(discord_new | head -1 | jq -r '.embeds[0].description')
check "mentions are disabled in every message" test "$(jq -c '.allowed_mentions' statuses.txt.discord | sort -u)" = '{"parse":[]}'

# The hook itself dying after "started" (here: checkout into a read-only
# worktree) must still end with a "failed" message.
(cd dev && echo x > newfile && git add newfile && git commit -q -m "add a file" && git push -q ../origin.git main)
chmod a-w "$WORKTREE"
dmark
out=$(manual_push "$T/push.env"); echo "$out" >> all-push-output.txt
chmod u+w "$WORKTREE"
check "discord: hook aborting mid-deploy -> started + failed" test "$(discord_titles)" = "🚀 Deploy started: App → production|❌ Deploy failed: App → production|"

touch statuses.txt.discord-fail
DOWN1=$(commit "discord returns 500")
out=$(manual_push "$T/push.env"); echo "$out" >> all-push-output.txt
rm statuses.txt.discord-fail
check "discord 500 -> says so" grep -q "git-deploy: discord notification failed (HTTP 500)" <<< "$out"
check "... and still deploys" grep -qx "$DOWN1" "$WORKTREE/.deployed"
check "... and reports success" bash -c "grep -qE '/deployments/50[0-9]{2}/statuses .*\"success\"' <(tail -1 '$T/statuses.txt')"

sed -i "s#^DISCORD_WEBHOOK_URL=.*#DISCORD_WEBHOOK_URL=http://127.0.0.1:$(free_port)/discord/1/SECRET-canary#" "$BARE/deploy.env"
DOWN2=$(commit "discord unreachable")
out=$(manual_push "$T/push.env"); echo "$out" >> all-push-output.txt
check "discord unreachable -> says so" grep -q "git-deploy: discord notification failed (unreachable)" <<< "$out"
check "... and still deploys" grep -qx "$DOWN2" "$WORKTREE/.deployed"

sed -i '/^DISCORD_WEBHOOK_URL=/d' "$BARE/deploy.env"
commit "no discord url" > /dev/null
dmark
out=$(manual_push "$T/push.env")
check "no URL -> no message" test -z "$(discord_new)"
if grep -qi discord <<< "$out"; then not_ok "... and no mention of it" "$out"; else ok "... and no mention of it"; fi

if grep -rqF SECRET-canary logs/ statuses.txt webhook.log all-push-output.txt; then
  not_ok "the webhook URL never leaks into logs, statuses or output" "$(grep -rF SECRET-canary logs/ statuses.txt webhook.log all-push-output.txt)"
else
  ok "the webhook URL never leaks into logs, statuses or output"
fi

# --- deploy.yml's wait/tail step ---------------------------------------

section "deploy-webhook.yml wait step"
"$PYTHON" - "$ROOT/template/deploy-webhook.yml.example" > wait.sh <<'EOF'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy"]["steps"]
print(next(s["run"] for s in steps if s["name"].startswith("Wait for the server")))
EOF
sed -i 's/sleep 3/sleep 0.2/' wait.sh
mkdir -p mockbin
cat > mockbin/gh <<'EOF'
#!/bin/sh
# The step only calls `gh api .../statuses --jq ...`; answer with the tsv
# that jq expression would produce, from a file the test controls.
cat "$MOCK_STATUS" 2> /dev/null || true
EOF
chmod +x mockbin/gh
run_wait() { PATH="$T/mockbin:$PATH" MOCK_STATUS="$T/mock-status" GITHUB_REPOSITORY=test/app DEPLOYMENT_ID=1 timeout 30 bash "$@"; }
LOG_URL="http://127.0.0.1:$API_PORT/logs/wf.log"

tail_scenario() { # tail_scenario <final state>
  rm -f mock-status; : > logs/wf.log
  (
    sleep 0.5; printf 'in_progress\t%s\tDeploying\n' "$LOG_URL" > mock-status
    for i in 1 2 3; do echo "line $i" >> logs/wf.log; sleep 0.4; done
    echo "last line" >> logs/wf.log
    printf '%s\t%s\tdone\n' "$1" "$LOG_URL" > mock-status
  ) &
  local rc=0; run_wait wait.sh > wait.out 2>&1 || rc=$?; wait
  echo "$rc"
}
rc=$(tail_scenario success)
check "success -> exit 0" test "$rc" -eq 0
check "every log line printed once, in order" test "$(grep -E '^(line [0-9]|last line)$' wait.out | tr '\n' ,)" = "line 1,line 2,line 3,last line,"
rc=$(tail_scenario failure)
check "failure -> exit 1" test "$rc" -eq 1
check "failure still prints the log tail" grep -qx "last line" wait.out
rm -f mock-status
sed 's/-ge 60/-ge 1/' wait.sh > wait-short.sh
rc=0; run_wait wait-short.sh > wait.out 2>&1 || rc=$?
check "no acknowledgement -> exit 1 with a hint" bash -c "test $rc -eq 1 && grep -q 'never acknowledged' '$T/wait.out'"

section "deploy-webhook.yml plan step"
"$PYTHON" - "$ROOT/template/deploy-webhook.yml.example" > plan.sh <<'EOF2'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["plan"]["steps"]
print(next(s["run"] for s in steps if s.get("id") == "pick"))
EOF2
TEMPLATE_ENVS=$("$PYTHON" -c 'import sys,yaml; print(next(s for s in yaml.safe_load(open(sys.argv[1]))["jobs"]["plan"]["steps"] if s.get("id")=="pick")["env"]["ENVIRONMENTS"])' "$ROOT/template/deploy-webhook.yml.example")
plan() { # plan <ENVIRONMENTS> <inputs json> -> prints the environments output, returns step's status
  : > plan.out
  ENVIRONMENTS="$1" INPUTS="$2" GITHUB_OUTPUT="$T/plan.out" bash plan.sh > plan.log 2>&1 || return $?
  sed -n 's/^environments=//p' plan.out
}
check "template default: production only" test "$(plan "$TEMPLATE_ENVS" '{"production":"true"}')" = '["production"]'
check "several ticked -> all, in ENVIRONMENTS order" test "$(plan "production beta" '{"beta":"true","production":"true"}')" = '["production","beta"]'
check "unticked ones are skipped" test "$(plan "production beta" '{"production":"false","beta":"true"}')" = '["beta"]'
check "real booleans work too" test "$(plan "production beta" '{"production":true,"beta":false}')" = '["production"]'
check "nothing ticked -> fails" bash -c "! ENVIRONMENTS=production INPUTS='{\"production\":\"false\"}' GITHUB_OUTPUT=/dev/null bash '$T/plan.sh' > /dev/null 2>&1"
check "listed without a checkbox -> fails" bash -c "! ENVIRONMENTS='production beta' INPUTS='{\"production\":\"true\"}' GITHUB_OUTPUT=/dev/null bash '$T/plan.sh' > /dev/null 2>&1"

echo
echo "$PASSED passed, $FAILED failed"
exit $(( FAILED > 100 ? 100 : FAILED ))
