#!/bin/sh
set -eu
# route_trace names the Forkop rule, action and outbound the generated
# sing-box config assigns to a connection (calculated, marked "simulated"),
# says why when the config cannot answer, and never returns secrets.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
TRACE="$LIB/diagnostics/route_trace.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cat >"$WORK/forkop" <<CONF
config settings 'settings'
	option config_path '$WORK/sing-box.json'
config section 'youtube'
	option action 'connection'
	option label 'YouTube'
config section 'discord'
	option action 'vpn'
	option label 'Discord'
config section 'main'
	option action 'connection'
	option label 'Main VPN'
	option proxy_string 'vless://secret-uuid@example.net:443'
config section 'off'
	option action 'connection'
	option enabled '0'
CONF

write_config() {
  cat >"$WORK/sing-box.json" <<JSON
{"route":{"final":"direct-out","rules":[
 {"action":"sniff","inbound":"tproxy-in"},
 {"inbound":"dns-in","action":"hijack-dns"},
 {"action":"reject","inbound":"tproxy-in","protocol":"quic"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["youtube.com","googlevideo.com"],"outbound":"youtube-out"},
 {"action":"reject","inbound":"tproxy-in","domain_suffix":["doubleclick.net"]},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["ru"],"outbound":"bypass-out"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["discord.com"],"source_ip_cidr":["192.168.1.40/32"],"outbound":"discord-out"}
 $1
]}}
JSON
}

trace() {
  FORKOP_CONFIG="$WORK/forkop" ucode -L "$LIB" "$TRACE" fixture "$1" "$2" TCP 443 "$3" '' || true
}

write_config ',{"action":"route","inbound":"tproxy-in","rule_set":["main-community"],"outbound":"main-urltest-out"}'
trace youtube.com '' 198.18.0.5 >"$WORK/youtube.json"
trace doubleclick.net '' 198.18.0.6 >"$WORK/block.json"
trace gosuslugi.ru '' 213.59.254.7 >"$WORK/bypass.json"
trace discord.com '' 198.18.0.7 >"$WORK/discord-any.json"
trace discord.com 192.168.1.40 198.18.0.7 >"$WORK/discord-dev.json"
trace discord.com 192.168.1.50 198.18.0.7 >"$WORK/discord-other.json"
write_config ''
trace example.org '' 93.184.216.34 >"$WORK/direct.json"
rm "$WORK/sing-box.json"
trace youtube.com '' 198.18.0.5 >"$WORK/noconfig.json"

node - "$WORK" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const dir = process.argv[2];
const read = (name) => JSON.parse(fs.readFileSync(`${dir}/${name}.json`, 'utf8'));
const brief = (t) => [t.rule.value, t.rule.reason ?? null, t.action.value, t.outbound.value];

const yt = read('youtube');
assert.deepEqual(brief(yt), ['YouTube', null, 'connection', 'youtube-out']);
assert.equal(yt.rule.provenance, 'simulated');
assert.equal(yt.rule.section, 'youtube');
assert.equal(yt.dpi, undefined, 'no DPI strategy is reported');

assert.deepEqual(brief(read('block')), [null, 'block', 'block', null]);
assert.deepEqual(brief(read('bypass')), [null, 'bypass', 'bypass', 'bypass-out']);

const any = read('discord-any');
assert.deepEqual([any.rule.provenance, any.rule.reason, any.rule.status], ['unknown', 'source_scoped_rule', 'undecidable']);
const dev = read('discord-dev');
assert.deepEqual(brief(dev), ['Discord', null, 'connection', 'discord-out'], 'legacy vpn action reads as connection');
assert.equal(dev.target.source_applied, true);
assert.equal(read('discord-other').rule.reason, 'undecidable_matcher');
assert.equal(read('discord-other').rule.status, 'undecidable');

assert.deepEqual(brief(read('direct')), [null, 'no_rule_matched', 'direct', 'direct-out']);
assert.equal(read('noconfig').rule.reason, 'singbox_config_unavailable');
assert.equal(read('noconfig').rule.status, 'unavailable');

for (const name of fs.readdirSync(dir).filter((f) => f.endsWith('.json') && f !== 'sing-box.json'))
  assert.doesNotMatch(fs.readFileSync(`${dir}/${name}`, 'utf8'), /secret|vless:/,
    `${name}: no secrets`);
NODE

echo "route_trace owner checks passed"
