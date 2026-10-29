#!/usr/bin/env bash
set -euo pipefail

# Stage 6.8.2: autotune targets are classified into DPI groups through the
# shared resolver (routing/resolve.uc); a group gets one recommendation only
# when its conclusive targets agree; policy and targets are written through
# UCI with a private save directory and never commit anything staged by
# someone else.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
# A call the uci test shim refused fails the test, even one it tolerated.
cleanup() {
  local rc=$?
  uci_cli_report || [ "$rc" != 0 ] || rc=1
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# Policy and targets are written through the uci CLI (UC-009).
# shellcheck source=tests/helpers/uci_cli/select.sh
source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"
export FORKOP_LIB="$LIB"
export FORKOP_AUTOTUNE_STATE_FILE="$WORK/etc/autotune/state.json"
export FORKOP_AUTOTUNE_LAST_DIR="$WORK/run/last" FORKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune"
export FORKOP_CONFIG_FILE="$WORK/config/forkop"
export FORKOP_AUTOTUNE_SINGBOX_CONFIG="$WORK/sing-box.json"
export FORKOP_AUTOTUNE_DIG="$WORK/dig"
export FORKOP_AUTOTUNE_UCI_SAVEDIR="$WORK/uci-save" FORKOP_AUTOTUNE_TMPDIR="$WORK/tmp"
export FORKOP_HISTORY_FILE="$WORK/etc/history.jsonl" FORKOP_RUNTIME_STATE_DIR="$WORK/run/state"
# A mode change syncs the autotune cron line: never the host's crontab.
export FORKOP_CRONTAB_FILE="$WORK/crontab" FORKOP_AUTOTUNE_CRONTAB="$WORK/crontab-cmd"
mkdir -p "$WORK/config" "$WORK/uci-save" "$WORK/tmp"
printf '#!/bin/sh\ncp "$1" "%s/crontab"\n' "$WORK" >"$WORK/crontab-cmd"
chmod +x "$WORK/crontab-cmd"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
manager() { ucode -L "$LIB" "$LIB/autotune/manager.uc" "$@"; }

# ---- pure aggregation ------------------------------------------------------
cat >"$WORK/aggregate.uc" <<'UC'
let g = require("autotune.groups");
let s = (selected, confidence, stable) => ({ status: "selected", selected, confidence, reason: "r_" + selected,
  candidates: map(stable, (id) => ({ id, stability: "stable" })) });
let out = {
  agree: g.aggregate([ { id: "a", summary: s("multisplit", "high", ["multisplit"]) },
                       { id: "b", summary: s("multisplit", "medium", ["multisplit"]) } ], "fake"),
  differ: g.aggregate([ { id: "a", summary: s("multisplit", "high", ["multisplit"]) },
                        { id: "b", summary: s("fake", "high", ["fake"]) } ], "default"),
  direct_ok: g.aggregate([ { id: "a", summary: s("multisplit", "high", ["multisplit"]) },
                           { id: "b", summary: s("direct", "high", ["direct", "multisplit"]) } ], "default"),
  direct_only: g.aggregate([ { id: "a", summary: s("multisplit", "high", ["multisplit"]) },
                             { id: "b", summary: s("direct", "high", ["direct"]) } ], "default"),
  all_direct: g.aggregate([ { id: "a", summary: s("direct", "high", ["direct"]) } ], "default"),
  active: g.aggregate([ { id: "a", summary: s("multisplit", "high", ["multisplit"]) } ], "multisplit"),
  inconclusive: g.aggregate([ { id: "a", summary: { status: "inconclusive", reason: "all_failed" } },
                              { id: "b", summary: null } ], "default"),
  empty: g.aggregate([], "default"),
  fp_same: g.fingerprint({ options: { a: "1", b: "2" } }) == g.fingerprint({ options: { b: "2", a: "1" } }),
  fp_diff: g.fingerprint({ options: { a: "1" } }) != g.fingerprint({ options: { a: "2" } })
};
print(sprintf("%J\n", out));
UC
ucode -L "$LIB" "$WORK/aggregate.uc" >"$WORK/aggregate.json"

# ---- classification --------------------------------------------------------
cat >"$WORK/config/forkop" <<'CONF'
config settings 'settings'
config section 'main'
	option action 'connection'
	option proxy_string 'vless://secret-uuid@example.net:443'
config section 'youtube'
	option action 'zapret'
	option label 'YouTube'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld'
config section 'z2'
	option action 'zapret2'
	option nfqws2_opt '--lua-desync=private-z2'
config section 'kids'
	option action 'zapret'
	option label 'Kids tablet'
	list source_ip_cidr '192.168.1.50'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=fake'
config autotune_target 'yt'
	option host 'www.youtube.com'
config autotune_target 'ytimg'
	option host 'i.ytimg.com'
config autotune_target 'vpn'
	option host 'telegram.org'
config autotune_target 'plain'
	option host 'example.org'
config autotune_target 'real'
	option host 'real.example.net'
config autotune_target 'nodns'
	option host 'missing.example.net'
config autotune_target 'lua'
	option host 'lua.example.net'
config autotune_target 'lists'
	option host 'listed.example.com'
config autotune_target 'scoped'
	option host 'kids.example.net'
config autotune_target 'off'
	option host 'off.example.com'
	option enabled '0'
CONF
cat >"$WORK/sing-box.json" <<'JSON'
{"route":{"final":"direct-out","rules":[
 {"action":"route","inbound":"tproxy-in","domain_suffix":["youtube.com","ytimg.com"],"outbound":"youtube-out"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["telegram.org"],"outbound":"main-out"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["lua.example.net"],"outbound":"z2-out"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["kids.example.net"],"source_ip_cidr":["192.168.1.50"],"outbound":"kids-out"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["example.org"],"outbound":"direct-out"},
 {"action":"route","inbound":"tproxy-in","rule_set":["remote-list"],"outbound":"main-out"}
]},"outbounds":[{"type":"direct","tag":"direct-out"},{"type":"vless","tag":"main-out"},
 {"type":"direct","tag":"youtube-out","routing_mark":16777217},{"type":"direct","tag":"kids-out","routing_mark":16777218},{"type":"direct","tag":"z2-out","routing_mark":33554433}]}
JSON
cat >"$WORK/dig" <<'SH'
#!/bin/sh
# dig +short +time=2 +tries=1 <host> A
case "$4" in
  missing.example.net) ;;
  real.example.net) echo 203.0.113.9 ;;
  *) echo 198.18.0.$(printf '%s' "$4" | wc -c) ;;
esac
SH
chmod +x "$WORK/dig"
cat >"$WORK/seed.uc" <<'UC'
let state = require("autotune.state");
let s = state.read();
let tune = (selected, confidence) => ({ status: "selected", selected, confidence, reason: "direct_failed_candidate_stable",
  target: { ip: "198.18.0.1" }, candidates: [ { id: "multisplit", stability: "stable", success: 5, attempted: 5, success_ratio: 1 },
  { id: "fake", stability: "stable", success: 5, attempted: 5, success_ratio: 1 } ] });
state.record_tune(s, "yt", tune("fake", "high"), {}, 100);
state.record_tune(s, "ytimg", tune("fake", "medium"), {}, 100);
state.write(s);
UC
ucode -L "$LIB" "$WORK/seed.uc"
manager groups >"$WORK/groups.json"

# ---- policy and targets (write) -------------------------------------------
before="$(cat "$WORK/config/forkop")"
manager policy-set mode recommend >"$WORK/mode.json"
manager policy-set mode recommend >"$WORK/mode-again.json"
if manager policy-set interval 10m >"$WORK/interval.json"; then fail "a too short interval must be refused"; fi
if manager policy-set nosuch 1 >"$WORK/unknown-option.json"; then fail "unknown options must be refused"; fi
echo "forkop.youtube.enabled='0'" >"$WORK/uci-save/forkop"
if manager policy-set confirmations 4 >"$WORK/staged.json"; then fail "staged UCI changes must block policy writes"; fi
rm -f "$WORK/uci-save/forkop"
manager policy-set confirmations 4 >"$WORK/confirmations.json"
manager target-set yt www.YouTube.com 1 192.0.2.53 >"$WORK/target-same.json"
manager target-set yt m.youtube.com >"$WORK/target-new-host.json"
manager target-set extra extra.example.com 0 >"$WORK/target-add.json"
if manager target-set youtube x.example.com >"$WORK/target-clash.json"; then fail "a target must not reuse a rule name"; fi
if manager target-set bad 'not a host' >"$WORK/target-bad.json"; then fail "invalid hosts must be refused"; fi
manager target-remove extra >"$WORK/target-remove.json"
if manager target-remove extra >"$WORK/target-remove-again.json"; then fail "removing a missing target must fail"; fi
manager status >"$WORK/status.json"
cp "$WORK/config/forkop" "$WORK/after.conf"

node - "$WORK" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const work = process.argv[2];
const read = (name) => JSON.parse(fs.readFileSync(`${work}/${name}.json`, 'utf8'));

const a = read('aggregate');
assert.deepEqual([a.agree.status, a.agree.candidate, a.agree.confidence, a.agree.representative],
  ['recommendation', 'multisplit', 'medium', 'a'], 'agreeing targets: the lowest confidence, the most confident representative');
assert.deepEqual([a.differ.status, a.differ.reason], ['conflict', 'targets_need_different_strategies']);
assert.deepEqual(a.differ.conflict, [{ target: 'a', selected: 'multisplit' }, { target: 'b', selected: 'fake' }]);
assert.deepEqual([a.direct_ok.status, a.direct_ok.candidate], ['recommendation', 'multisplit'],
  'a target that works directly accepts a candidate stable for it');
assert.deepEqual([a.direct_only.status, a.direct_only.reason], ['conflict', 'candidate_not_stable_for_all']);
assert.deepEqual([a.all_direct.status, a.all_direct.reason], ['direct_stable', 'direct_not_applicable'],
  'Forkop never turns DPI off by itself');
assert.deepEqual([a.active.status, a.active.reason], ['no_change', 'candidate_already_active']);
assert.deepEqual([a.inconclusive.status, a.inconclusive.reason], ['inconclusive', 'all_failed']);
assert.deepEqual([a.empty.status, a.empty.reason], ['inconclusive', 'no_targets']);
assert(a.fp_same && a.fp_diff, 'rule fingerprints follow the options, not their order');

const g = read('groups');
assert.deepEqual(Object.keys(g.groups), ['youtube', 'kids']);
const yt = g.groups.youtube;
// A rule limited to devices owns its target for those devices; the group says so.
assert.deepEqual([g.groups.kids.label, g.groups.kids.targets, g.groups.kids.source_scoped], ['Kids tablet', ['scoped'], true]);
assert.equal(yt.source_scoped, false);
assert.deepEqual([yt.label, yt.targets, yt.current, yt.custom], ['YouTube', ['yt', 'ytimg'], 'multisplit', false]);
assert.deepEqual([yt.result.status, yt.result.candidate, yt.result.confidence, yt.result.representative],
  ['recommendation', 'fake', 'medium', 'yt']);
const outside = Object.fromEntries(g.outside.map((o) => [o.id, [o.reason, o.detail]]));
assert.deepEqual(outside, {
  vpn: ['routed_through_connection', 'main'],
  plain: ['no_dpi_rule', null],
  real: ['target_not_fakeip_routed', null],
  nodns: ['target_unresolved', null],
  lua: ['provider_not_supported', 'z2'],
  lists: ['rule_owner_undecidable', 'undecidable_matcher'],
  off: ['target_disabled', null],
});
assert.doesNotMatch(fs.readFileSync(`${work}/groups.json`, 'utf8'), /secret|private-z2|dpi-desync/, 'no raw strategies or secrets');

assert.deepEqual([read('mode').status, read('mode').value, read('mode').previous], ['ok', 'recommend', 'off']);
assert.equal(read('interval').reason, 'duration_out_of_range');
assert.equal(read('unknown-option').reason, 'unknown_option');
assert.equal(read('staged').reason, 'uncommitted_uci_changes');
assert.equal(read('confirmations').value, 4);
assert.equal(read('target-add').target.enabled, false);
assert.equal(read('target-clash').reason, 'id_in_use');
assert.equal(read('target-bad').reason, 'invalid_host');
assert.equal(read('target-remove-again').reason, 'unknown_target');

const status = read('status');
assert.deepEqual([status.policy.mode, status.policy.confirmations], ['recommend', 4]);
const byId = Object.fromEntries(status.targets.map((t) => [t.id, t]));
assert.deepEqual([byId.yt.host, byId.yt.resolver, byId.yt.last], ['m.youtube.com', null, null],
  'a new host drops the results of the old one');
assert.equal(byId.ytimg.last.selected, 'fake', 'other targets keep their results');
assert.equal(byId.extra, undefined);

const history = fs.readFileSync(`${work}/etc/history.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
assert.deepEqual(history.map((e) => [e.kind, e.status]), [['autotune_mode', 'success']],
  'only a real mode change is recorded, once');

const conf = fs.readFileSync(`${work}/after.conf`, 'utf8');
for (const kept of ["option proxy_string 'vless://secret-uuid@example.net:443'", "option nfqws2_opt '--lua-desync=private-z2'"])
  assert(conf.includes(kept), `rules are untouched: ${kept}`);
assert.match(conf, /config autotune 'autotune'\n\toption mode 'recommend'\n\toption confirmations '4'/);
console.log('autotune groups checks passed');
NODE
