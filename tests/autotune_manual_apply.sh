#!/usr/bin/env bash
set -euo pipefail

# Stage 6.9.1: manual apply of a confirmed group recommendation (mode
# recommend). The caller names only the group; the candidate, the current
# strategy, the owner and the measurement come from the backend and are
# checked again right before the Stage 5 plan + apply transaction
# (stand-ins here: tests/helpers/autotune_scheduler). Every refusal happens
# before any plan or apply. A manual apply never counts against the daily
# limit of autonomous applies, keeps the cooldowns and is recorded in the
# history as manual.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

ACL="$ROOT_DIR/luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json"
CLI="$ROOT_DIR/forkop/files/usr/bin/forkop"

# The catalog validates candidates with the installed nfqws: a stand-in that
# accepts every option set unless told to reject.
export ZAPRET_NFQWS_BIN="$WORK/nfqws"
cat >"$ZAPRET_NFQWS_BIN" <<SH
#!/bin/sh
[ -e "$WORK/nfqws.reject" ] && exit 1
exit 0
SH
chmod +x "$ZAPRET_NFQWS_BIN"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$FORKOP_AUTOTUNE_STATE_FILE" "$1"; }
applies() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^apply ' "$WORK/tune/apply.log" || true; else echo 0; fi; }
plans() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^plan ' "$WORK/tune/apply.log" || true; else echo 0; fi; }
apply_events() { if [ -e "$FORKOP_HISTORY_FILE" ]; then node -e 'console.log(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(e=>e.kind=="autotune_apply").map(e=>e.status+":"+(e.trigger||"-")+":"+(e.candidate||"-")).join(","))' "$FORKOP_HISTORY_FILE"; fi; }
confirm_youtube() {
  manager run youtube >/dev/null
  manager run youtube >"$WORK/confirm.json"
  [ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "youtube not confirmed: $(cat "$WORK/confirm.json")"
}
# apply <name>: a manual apply of youtube, output in $WORK/<name>.json.
apply() { manager apply youtube >"$WORK/$1.json" || true; }
got() { json_get "$WORK/$1.json" "$2"; }
# refused <name> <reason>: refused before any plan or apply.
refused() {
  local before_plans before_applies
  before_plans="$(plans)"; before_applies="$(applies)"
  apply "$1"
  [ "$(got "$1" status)" != '"ok"' ] || fail "$1 must not succeed: $(cat "$WORK/$1.json")"
  [ "$(got "$1" result)" = '"refused"' ] || fail "$1 result: $(cat "$WORK/$1.json")"
  [ "$(got "$1" reason)" = "\"$2\"" ] || fail "$1 reason (want $2): $(cat "$WORK/$1.json")"
  [ "$(plans)" = "$before_plans" ] || fail "$1: no Stage 5 plan"
  [ "$(applies)" = "$before_applies" ] || fail "$1: no Stage 5 apply"
}

manager policy-set mode recommend >/dev/null

# ---- the mode decides -----------------------------------------------------------
confirm_youtube
manager policy-set mode off >/dev/null
refused mode-off mode_off
manager policy-set mode recommend >/dev/null

# ---- a pending (not yet confirmed) recommendation is refused --------------------
state_edit 's.groups={}'
manager run youtube >/dev/null
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = false ] || fail "fixture: one run is pending"
refused pending not_confirmed
manager apply nosuch >"$WORK/nosuch.json" || true
[ "$(got nosuch reason)" = '"no_recommendation"' ] || fail "unknown group: $(cat "$WORK/nosuch.json")"
manager apply 'you;tube' >"$WORK/bad-name.json" || true
[ "$(got bad-name reason)" = '"invalid_group"' ] || fail "invalid group name: $(cat "$WORK/bad-name.json")"

# ---- a valid manual apply goes through Stage 5 ----------------------------------
confirm_youtube
# The daily limit of autonomous applies is used up: a manual apply is not
# blocked by it.
manager policy-set max_applies_per_day 1 >/dev/null
state_edit "s.applies=[{at:$(date +%s),group:'youtube',candidate:'fake',status:'applied',counted:true,trigger:'automatic'}]"
apply valid
[ "$(got valid status)" = '"ok"' ] || fail "valid apply: $(cat "$WORK/valid.json")"
[ "$(got valid result)" = '"applied"' ] || fail "valid result"
[ "$(got valid candidate)" = '"fake"' ] || fail "the candidate comes from the backend"
[ "$(got valid trigger)" = '"manual"' ] || fail "trigger reported"
grep -Fxq 'plan www.youtube.com fake 192.0.2.53' "$WORK/tune/apply.log" || fail "plan from the representative's measurement: $(cat "$WORK/tune/apply.log")"
grep -Fxq 'apply youtube fake 192.0.2.53' "$WORK/tune/apply.log" || fail "Stage 5 apply of that plan"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" applies.1.trigger)" = '"manual"' ] || fail "apply record marked manual"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" applies.1.counted)" = false ] || fail "a manual apply is not counted against the auto limit"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" applies.1.attempted)" = true ] || fail "a manual apply is recorded as attempted"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.last_apply.trigger)" = '"manual"' ] || fail "last apply of the group"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.pending)" = null ] || fail "confirmations start over"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" worker.kind)" != '"apply"' ] || fail "the last run stays the worker record"
[ "$(apply_events)" = "success:manual:fake" ] || fail "history: $(apply_events)"
ucode -L "$LIB" "$LIB/diagnostics/health.uc" history >"$WORK/history.json"
node -e 'const h=require(process.argv[1]);const e=h.events.filter(x=>x.kind=="autotune_apply");if(e.length!=1||e[0].trigger!="manual"||e[0].candidate!="fake")throw Error(JSON.stringify(h))' "$WORK/history.json" ||
  fail "history view keeps the trigger and the candidate"
if find "$WORK/tmp" -name 'forkop-autotune-apply.*' | grep -q .; then fail "selection and plan files are removed"; fi

# ---- an applied recommendation is not applied again ----------------------------
refused again not_confirmed

# ---- stale: the rule changed after the measurement -----------------------------
confirm_youtube
cp "$FORKOP_CONFIG_FILE" "$WORK/config.orig"
sed -i "s/option label 'YouTube'/option label 'YouTube 2'/" "$FORKOP_CONFIG_FILE"
refused fingerprint rule_changed
cp "$WORK/config.orig" "$FORKOP_CONFIG_FILE"
state_edit 's.groups.youtube.current="fake_multisplit"'
refused strategy strategy_changed
confirm_youtube
state_edit 's.groups.youtube.targets=["yt"]'
refused targets targets_changed
confirm_youtube
state_edit 's.groups.youtube.last.at=1'
refused old recommendation_stale
confirm_youtube
rm -f "$FORKOP_AUTOTUNE_LAST_DIR/yt.json"
refused lost-measurement measurement_unavailable
confirm_youtube

# ---- the routing owner changed -------------------------------------------------
cp "$FORKOP_AUTOTUNE_SINGBOX_CONFIG" "$WORK/sing-box.orig"
sed -i 's/"domain_suffix":\["youtube.com","ytimg.com"\],"outbound":"youtube-out"/"domain_suffix":["youtube.com","ytimg.com"],"outbound":"discord-out"/' "$FORKOP_AUTOTUNE_SINGBOX_CONFIG"
manager groups >"$WORK/owner-groups.json"
[ "$(json_get "$WORK/owner-groups.json" groups.youtube)" = null ] || fail "fixture: youtube lost its targets"
refused owner owner_changed
cp "$WORK/sing-box.orig" "$FORKOP_AUTOTUNE_SINGBOX_CONFIG"
# Stage 5 finds another owner right before the change.
export STUB_PLAN_OWNER=discord
apply plan-owner
unset STUB_PLAN_OWNER
[ "$(got plan-owner result)" = '"refused"' ] || fail "plan owner: $(cat "$WORK/plan-owner.json")"
[ "$(got plan-owner reason)" = '"owner_changed"' ] || fail "plan owner reason"
[ "$(applies)" = 1 ] || fail "plan owner: no apply"

# ---- the stored recommendation is not applicable -------------------------------
confirm_youtube
state_edit 's.groups.youtube.result.status="conflict"'
refused conflict conflict
confirm_youtube
state_edit 's.groups.youtube.result.candidate="direct"; s.groups.youtube.pending.candidate="direct"'
refused direct direct_not_applicable
selected www.youtube.com direct high; selected i.ytimg.com direct high
manager run youtube >/dev/null
refused direct-stable direct_not_applicable
selected www.youtube.com fake high; selected i.ytimg.com fake high
confirm_youtube
touch "$WORK/nfqws.reject"
refused unsupported candidate_unsupported
rm -f "$WORK/nfqws.reject"
state_edit "s.groups.youtube.cooldowns={fake:$(( $(date +%s) + 3600 ))}"
refused cooldown candidate_in_cooldown
state_edit 's.groups.youtube.cooldowns={}'
manager policy-set min_confidence high >/dev/null
state_edit 's.groups.youtube.result.confidence="medium"'
refused confidence confidence_too_low
confirm_youtube

# ---- guard, snapshot, service action, unresolved Stage 5 transaction and a -----
# ---- Forkop stopped by the user (D-15, UC-056) ------------------------------------
for case in guard snapshot reload unresolved stopped; do
  case "$case" in
    guard) printf '{"state":null,"guards":["ForkopConfigRestoreDpiGuard"]}\n'; want=dpi_guard_present ;;
    snapshot) printf '{"state":null,"guards":[],"snapshot_operation":true}\n'; want=snapshot_operation_active ;;
    reload) printf '{"state":null,"guards":[],"service_action":"reload_pending"}\n'; want=reload_pending ;;
    unresolved) printf '{"state":{"phase":"verifying"},"guards":[],"resolved":false}\n'; want=apply_unresolved ;;
    stopped) printf '{"state":null,"guards":[],"service_stopped":true}\n'; want=service_stopped ;;
  esac >"$STUB_APPLY_STATUS"
  refused "blocked-$case" "$want"
done
rm -f "$STUB_APPLY_STATUS"

# ---- a custom strategy of the user is kept -----------------------------------------
manager run discord >/dev/null; manager run discord >/dev/null
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.discord.ready)" = true ] || fail "fixture: discord confirmed"
before_plans="$(plans)"
manager apply discord >"$WORK/custom.json" || true
[ "$(got custom reason)" = '"custom_strategy_kept"' ] || fail "custom: $(cat "$WORK/custom.json")"
[ "$(plans)" = "$before_plans" ] || fail "a custom strategy is never planned over"

# ---- a concurrent worker ---------------------------------------------------------
mkdir -p "$FORKOP_AUTOTUNE_STATE_DIR"
flock "$FORKOP_AUTOTUNE_STATE_DIR/worker.lock" sleep 5 &
BG_PIDS+=($!)
for _ in $(seq 50); do flock -n "$FORKOP_AUTOTUNE_STATE_DIR/worker.lock" true || break; sleep 0.1; done
apply busy
[ "$(got busy status)" = '"busy"' ] || fail "busy: $(cat "$WORK/busy.json")"
manager apply-async youtube >"$WORK/busy-async.json" || true
[ "$(got busy-async status)" = '"busy"' ] || fail "busy async: $(cat "$WORK/busy-async.json")"
kill -9 "${BG_PIDS[-1]}" 2>/dev/null || true
wait "${BG_PIDS[-1]}" 2>/dev/null || true
for _ in $(seq 50); do flock -n "$FORKOP_AUTOTUNE_STATE_DIR/worker.lock" true && break; sleep 0.1; done

# ---- Stage 5 outcomes ------------------------------------------------------------
now_applies="$(applies)"
outcome() { # name stage5-json want-result want-status cooldown(yes|no) history
  printf '%s\n' "$2" >"$WORK/tune/apply.json"
  state_edit 's.groups.youtube.cooldowns={}'
  confirm_youtube
  apply "$1"
  [ "$(got "$1" result)" = "\"$3\"" ] || fail "$1 result: $(cat "$WORK/$1.json")"
  [ "$(got "$1" status)" = "\"$4\"" ] || fail "$1 status: $(cat "$WORK/$1.json")"
  local cool; cool="$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)"
  if [ "$5" = yes ]; then [ "$cool" != null ] || fail "$1 cools the candidate down"; else [ "$cool" = null ] || fail "$1 does not cool down"; fi
  [ "$(apply_events | tr ',' '\n' | tail -n1)" = "$6" ] || fail "$1 history: $(apply_events)"
  now_applies=$((now_applies + 1))
  [ "$(applies)" = "$now_applies" ] || fail "$1: one Stage 5 apply"
  rm -f "$WORK/tune/apply.json"
}
# A raw strategy in the Stage 5 output must never reach the job or the state.
RAW='"mutation":{"section":"youtube","option":"nfqws_opt","from":"--dpi-desync=multisplit","to":"--dpi-desync=fake"}'
outcome rolled-back "{\"status\":\"rolled_back\",\"reason\":\"verification_failed\",$RAW}" rolled_back failed yes recovered:manual:fake
outcome attention "{\"status\":\"needs_attention\",\"reason\":\"lkg_confirm_failed\",$RAW}" needs_attention failed yes failure:manual:fake
outcome recovered "{\"status\":\"failed\",\"reason\":\"reload_failed_recovered\",$RAW}" failed failed yes failure:manual:fake
outcome applied "{\"status\":\"applied\",\"reason\":null,$RAW}" applied ok no success:manual:fake
# Stage 5 finds the configuration changed: nothing changed, the confirmation stays.
printf '{"status":"stale","reason":"config_changed"}\n' >"$WORK/tune/apply.json"
confirm_youtube
apply stage5-stale
[ "$(got stage5-stale result)" = '"stale"' ] || fail "stage 5 stale: $(cat "$WORK/stage5-stale.json")"
[ "$(got stage5-stale reason)" = '"config_changed"' ] || fail "stage 5 stale reason"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "a stale plan keeps the confirmation"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.cooldowns.fake)" = null ] || fail "a stale plan does not cool down"
rm -f "$WORK/tune/apply.json"
node -e 'const s=require(process.argv[1]);if(s.applies.some(a=>a.trigger=="manual"&&a.counted))throw Error("manual counted")' "$FORKOP_AUTOTUNE_STATE_FILE" ||
  fail "no manual apply counts against the daily limit"
if grep -E 'dpi-desync|nfqws_opt' "$FORKOP_AUTOTUNE_STATE_FILE" >/dev/null; then fail "no raw strategies in the state"; fi

# ---- the client cannot choose the candidate --------------------------------------
confirm_youtube
FORKOP_LIB="$LIB" ucode "$CLI" autotune_apply youtube multisplit >"$WORK/inject.json" || true
[ "$(got inject candidate)" = '"fake"' ] || fail "injected candidate ignored: $(cat "$WORK/inject.json")"
grep -q '^apply youtube multisplit' "$WORK/tune/apply.log" && fail "a client candidate is never planned"
grep -Fq 'autotune_apply: [ "autotune/manager.uc", "apply", 1 ]' "$CLI" || fail "the CLI passes the group only"
grep -Fq 'autotune_apply_async: [ "autotune/manager.uc", "apply-async", 1 ]' "$CLI" || fail "the async CLI passes the group only"

# ---- read-only role ---------------------------------------------------------------
node - "$ACL" <<'NODE'
const acl = JSON.parse(require('node:fs').readFileSync(process.argv[2], 'utf8'))['luci-app-forkop'];
const allowed = (c) => Object.entries(acl.read.file).some(([p, perms]) => perms.includes('exec') &&
  new RegExp('^' + p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\\*/g, '.*') + '$').test(c));
for (const cli of ['/usr/bin/forkop', '/usr/libexec/forkop-ro'])
  for (const c of [`${cli} autotune_apply youtube`, `${cli} autotune_apply_async youtube`,
    `${cli} autotune_apply youtube fake`])
    if (allowed(c)) throw Error(`read role may execute ${c}`);
if (!allowed('/usr/libexec/forkop-ro autotune_run_status 1_1')) throw Error('read role lost the job status');
NODE

# ---- background job: the page can leave and come back ---------------------------
confirm_youtube
export STUB_APPLY_SLEEP=3
manager apply-async youtube >"$WORK/async.json"
unset STUB_APPLY_SLEEP
job="$(node -e 'console.log(require(process.argv[1]).job)' "$WORK/async.json")"
[ -n "$job" ] && [ "$job" != undefined ] || fail "async apply: $(cat "$WORK/async.json")"
for _ in $(seq 100); do
  manager status >"$WORK/async-status.json"
  [ "$(json_get "$WORK/async-status.json" worker.phase)" = '"applying"' ] && break; sleep 0.1
done
[ "$(json_get "$WORK/async-status.json" worker.kind)" = '"apply"' ] || fail "status names the running apply: $(cat "$WORK/async-status.json")"
[ "$(json_get "$WORK/async-status.json" worker.job)" = "\"$job\"" ] || fail "status carries the job to resume"
[ "$(json_get "$WORK/async-status.json" worker.state)" = '"running"' ] || fail "the apply is reported running"
manager run-status "$job" >"$WORK/job-running.json"
[ "$(json_get "$WORK/job-running.json" job.kind)" = '"apply"' ] || fail "job kind: $(cat "$WORK/job-running.json")"
[ "$(json_get "$WORK/job-running.json" job.state)" = '"running"' ] || fail "job running: $(cat "$WORK/job-running.json")"
[ "$(json_get "$WORK/job-running.json" job.progress.phase)" = '"applying"' ] || fail "job phase: $(cat "$WORK/job-running.json")"
# Another apply or run while this one runs.
manager apply youtube >"$WORK/while-running.json" || true
[ "$(got while-running status)" = '"busy"' ] || fail "concurrent apply: $(cat "$WORK/while-running.json")"
manager run youtube >"$WORK/run-while.json" || true
[ "$(got run-while status)" = '"busy"' ] || fail "concurrent run: $(cat "$WORK/run-while.json")"
for _ in $(seq 100); do
  manager run-status "$job" >"$WORK/job.json"
  [ "$(json_get "$WORK/job.json" job.state)" = '"finished"' ] && break; sleep 0.1
done
[ "$(json_get "$WORK/job.json" job.result.result)" = '"applied"' ] || fail "job result: $(cat "$WORK/job.json")"
[ "$(json_get "$WORK/job.json" job.result.candidate)" = '"fake"' ] || fail "job candidate"
if grep -E 'dpi-desync|nfqws_opt|--filter' "$WORK/job.json" "$WORK/job-running.json" "$WORK/async-status.json" >/dev/null; then
  fail "no raw strategy in the job or the status"
fi
manager status >"$WORK/after-job.json"
[ "$(json_get "$WORK/after-job.json" worker.kind)" != '"apply"' ] || fail "the finished apply leaves the last run as the worker record"

# ---- a crash during a manual apply ---------------------------------------------
confirm_youtube
before_events="$(apply_events)"; before_applies="$(applies)"
# The worker leads a process group of its own, so the crash kills exactly its
# tree: the manager, the Stage 5 stand-in and the stand-in's sleep, which
# inherited the worker lock as a real apply would. Never a process matched by
# name, which may belong to another test or to the host.
STUB_APPLY_SLEEP=10 setsid ucode -L "$LIB" "$LIB/autotune/manager.uc" apply youtube >/dev/null &
pid=$!
for _ in $(seq 100); do [ "$(applies)" != "$before_applies" ] && break; sleep 0.1; done
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" worker.phase)" = '"applying"' ] || fail "the apply is marked applying"
[ "$(cut -d' ' -f5 "/proc/$pid/stat")" = "$pid" ] || fail "fixture: the worker leads its own process group"
kill -9 -- "-$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
for _ in $(seq 50); do flock -n "$FORKOP_AUTOTUNE_STATE_DIR/worker.lock" true && break; sleep 0.1; done
manager run youtube >"$WORK/after-crash.json"
node -e 'const s=require(process.argv[1]);const a=s.applies[s.applies.length-1];
if(a.reason!="worker_crashed_during_apply"||a.trigger!="manual"||a.counted!==false||a.attempted!==true)throw Error(JSON.stringify(a));
if(!(s.groups.youtube.cooldowns.fake>Date.now()/1000))throw Error("no cooldown")' "$FORKOP_AUTOTUNE_STATE_FILE" ||
  fail "a crashed manual apply cools down and is not counted: $(cat "$FORKOP_AUTOTUNE_STATE_FILE")"
[ "$(apply_events)" = "$before_events" ] || fail "no apply event is guessed after a crash"

echo "autotune manual apply: OK"
