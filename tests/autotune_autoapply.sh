#!/usr/bin/env bash
set -euo pipefail

# Autonomous application of a confirmed group recommendation is off: the mode
# "auto" is refused, a configuration that still stores it reads as
# "recommend", and a scheduled run only measures. autotune/autoapply.uc still
# decides (the pure matrix below), and with no "auto" mode it always answers
# mode_not_auto, so nothing reaches the Stage 5 plan + apply transaction
# (stand-ins here: tests/helpers/autotune_scheduler).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

state_edit() { node -e 'const f=process.argv[1],s=require(f);(new Function("s",process.argv[2]))(s);require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$FORKOP_AUTOTUNE_STATE_FILE" "$1"; }
# The next scheduled run is due and its turn is the youtube group.
scheduled_youtube() { state_edit 's.next_run_at=1; s.rotation=1'; manager if-due >"$WORK/$1.json"; }
confirm_youtube() {
  manager run youtube >/dev/null
  manager run youtube >"$WORK/confirm.json"
  [ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = true ] || fail "youtube not confirmed: $(cat "$WORK/confirm.json")"
}
applies() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^apply ' "$WORK/tune/apply.log" || true; else echo 0; fi; }
plans() { if [ -e "$WORK/tune/apply.log" ]; then grep -c '^plan ' "$WORK/tune/apply.log" || true; else echo 0; fi; }
decision() { json_get "$WORK/$1.json" groups.youtube.decision; }
history_kinds() { if [ -e "$FORKOP_HISTORY_FILE" ]; then node -e 'console.log(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(e=>e.kind=="autotune_apply").map(e=>e.status).join(","))' "$FORKOP_HISTORY_FILE"; fi; }

# ---- pure decision and outcome matrix --------------------------------------
cat >"$WORK/pure.uc" <<'UC'
let a = require("autotune.autoapply");
let policy = { mode: "auto", apply_min_confidence: "high", max_applies_per_day: 1 };
let ok = { status: "recommendation", candidate: "fake", confidence: "high" };
let base = { policy, trigger: "schedule", group: { ready: true }, result: ok, custom: false, applies: [], now: 100000, cooldown_until: null };
let d = (over) => a.decide({ ...base, ...over }).reason;
print(sprintf("%J\n", {
  ok: a.decide(base),
  recommend: d({ policy: { ...policy, mode: "recommend" } }),
  manual: d({ trigger: "manual" }),
  unconfirmed: d({ group: { ready: false } }),
  conflict: d({ result: { status: "conflict" } }),
  direct: d({ result: { ...ok, candidate: "direct" } }),
  medium: d({ result: { ...ok, confidence: "medium" } }),
  custom: d({ custom: true }),
  cooldown: d({ cooldown_until: 100001 }),
  cooldown_over: d({ cooldown_until: 100000 }),
  disabled: d({ policy: { ...policy, max_applies_per_day: 0 } }),
  limit: d({ applies: [ { at: 99000, counted: true } ] }),
  limit_old: d({ applies: [ { at: 100000 - 86400, counted: true } ] }),
  limit_uncounted: d({ applies: [ { at: 99000, counted: false } ] }),
  outcomes: map([ { status: "applied" }, { status: "rolled_back" }, { status: "no_change_required" }, { status: "stale" },
    { status: "busy" }, { status: "failed" }, { status: "needs_attention" }, null ], (r) => a.outcome(r))
}));
UC
ucode -L "$LIB" "$WORK/pure.uc" >"$WORK/pure.json"
node - "$WORK/pure.json" <<'NODE'
const assert = require('node:assert/strict');
const p = require(process.argv[2]);
assert.deepEqual(p.ok, { apply: true, reason: null });
assert.deepEqual([p.recommend, p.manual, p.unconfirmed, p.conflict, p.direct, p.medium, p.custom, p.cooldown],
  ['mode_not_auto', 'manual_run', 'not_confirmed', 'no_recommendation', 'direct_not_applicable', 'confidence_too_low',
   'custom_strategy_kept', 'candidate_in_cooldown']);
assert.equal(p.cooldown_over, null, 'a cooldown ends at its time');
assert.deepEqual([p.disabled, p.limit, p.limit_old, p.limit_uncounted], ['applies_disabled', 'daily_limit_reached', null, null]);
const o = p.outcomes.map((x) => [x.status, x.counted, x.cooldown, x.reset, x.history]);
assert.deepEqual(o, [
  ['applied', true, false, true, 'success'],
  ['rolled_back', true, true, true, 'recovered'],
  ['no_change_required', false, false, true, null],
  ['stale', false, false, false, null],
  ['busy', false, false, false, null],
  ['failed', true, true, true, 'failure'],
  ['needs_attention', true, true, true, 'failure'],
  ['unknown', true, true, true, 'failure'],
]);
NODE

# ---- mode recommend: a confirmed recommendation is only shown ---------------
manager policy-set mode recommend >/dev/null
confirm_youtube
scheduled_youtube recommend
[ "$(decision recommend)" = '"mode_not_auto"' ] || fail "recommend mode: $(cat "$WORK/recommend.json")"
[ "$(plans)" = 0 ] || fail "recommend mode never plans"

# ---- mode auto is refused ------------------------------------------------------
manager policy-set mode auto >"$WORK/auto.json" || true
[ "$(json_get "$WORK/auto.json" status)" = '"failed"' ] || fail "mode auto must be refused: $(cat "$WORK/auto.json")"
[ "$(json_get "$WORK/auto.json" reason)" = '"invalid_mode"' ] || fail "refusal reason: $(cat "$WORK/auto.json")"
manager status >"$WORK/status.json"
[ "$(json_get "$WORK/status.json" policy.mode)" = '"recommend"' ] || fail "the refused mode changed the policy: $(cat "$WORK/status.json")"

# ---- a stored auto reads as recommend and never applies -------------------------
sed -i "s/option mode 'recommend'/option mode 'auto'/" "$FORKOP_CONFIG_FILE"
grep -q "option mode 'auto'" "$FORKOP_CONFIG_FILE" || fail "fixture: the stored mode must be auto"
manager status >"$WORK/stored.json"
[ "$(json_get "$WORK/stored.json" policy.mode)" = '"recommend"' ] || fail "stored auto: $(cat "$WORK/stored.json")"
confirm_youtube
scheduled_youtube stored-auto
[ "$(decision stored-auto)" = '"mode_not_auto"' ] || fail "stored auto run: $(cat "$WORK/stored-auto.json")"
[ "$(plans)" = 0 ] || fail "a scheduled run never plans"
[ "$(applies)" = 0 ] || fail "a scheduled run never applies"
[ -z "$(history_kinds)" ] || fail "no autotune apply in the history: $(history_kinds)"

echo "autotune autoapply: OK"
