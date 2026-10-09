#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
WORK_DIR="${DNS114_WORK_DIR_OUTPUT:-}"
if [ -n "$WORK_DIR" ]; then
  mkdir -p "$WORK_DIR"
else
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "source_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "bypass.example" ],
      "source_ip_cidr": [ "192.0.2.20/32" ]
    },
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "excluded_source_ip_cidr": [ "192.0.2.133/32" ],
      "community_lists": [ "discord" ],
      "domain_suffix": [ "vpn.example" ]
    }
  ]
}
JSON

generate() {
  local version="$1"
  local output="$WORK_DIR/config-$version.json"
  mkdir -p "$output.section-cache" "$output.rulesets"
  printf '%s\n' '{"version":3,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}' > "$output.rulesets/vpn-community-subnets-lists-ruleset.json"
  ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1" "" "$version"
}

generate 1.12.25
generate 1.13.18
generate 1.14.0

DNS114_WORK_DIR="$WORK_DIR" ucode -e '
let fs = require("fs");

function config(version) { return json(fs.readfile(getenv("DNS114_WORK_DIR") + "/config-" + version + ".json")); }
function rules(value) { return value.dns.rules || []; }
function contains(value, needle) {
    if (type(value) == "array") {
        for (let item in value) if (item == needle) return true;
    }
    return value == needle;
}
function domain_rule(rule) {
    if (rule == null) return false;
    if (contains(rule.domain_suffix, "bypass.example")) return true;
    for (let child in rule.rules || []) if (domain_rule(child)) return true;
    return false;
}
function no_empty_children(rule) {
    for (let child in rule.rules || []) {
        assert(length(child) > 0, "logical DNS rule must not contain an empty matcher");
        no_empty_children(child);
    }
}
function find(value, predicate) {
    for (let rule in rules(value)) if (predicate(rule)) return rule;
    return null;
}
function index(value, predicate) {
    let all = rules(value);
    for (let i = 0; i < length(all); i++) if (predicate(all[i])) return i;
    return -1;
}
function assert(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
function fakeip_tag(value) {
    for (let server in value.dns.servers || [])
        if (server.type == "fakeip") return server.tag;
    return null;
}
function address_only(rule) {
    if (rule.type == "logical") {
        for (let child in rule.rules || [])
            if (contains(child.query_type, "A") && contains(child.query_type, "AAAA")) return true;
        return false;
    }
    return contains(rule.query_type, "A") && contains(rule.query_type, "AAAA");
}

for (let version in [ "1.12.25", "1.13.18", "1.14.0" ]) {
    let value = config(version);
    let tag = fakeip_tag(value);
    assert(tag != null, version + " must configure a FakeIP DNS server");
    let count = 0;
    for (let rule in rules(value)) {
        if (rule.server != tag) continue;
        count++;
        assert(address_only(rule), version + " must send only A/AAAA queries to FakeIP");
    }
    assert(count > 1, version + " fixture must exercise the FakeIP probe and section rules");
}

for (let version in [ "1.12.25", "1.13.18" ]) {
    let value = config(version);
    let probe = find(value, r => r.type == "logical" && r.action == "route" && r.server == "dnsmasq-server" && domain_rule(r));
    let fallback = find(value, r => r.action == "route" && r.server == "dns-server" && domain_rule(r));
    assert(probe != null && probe.rules[1].match_response == null, version + " must retain the legacy dnsmasq route filter");
    assert(fallback != null, version + " must retain the normal resolver fallback");
    assert(find(value, r => (r.action == "evaluate" || r.action == "respond") && domain_rule(r)) == null, version + " emitted unsupported 1.14 DNS actions");
}

let value = config("1.14.0");
for (let rule in rules(value)) no_empty_children(rule);
let discord_query = find(value, r => r.server == fakeip_tag(value) &&
    match(sprintf("%J", r), /vpn-discord-community-ruleset/) != null);
assert(discord_query != null && discord_query.match_response == null,
    "Discord DNS must select its domain rule set before resolving shared Cloudflare IPs");
assert(discord_query.type == "logical" && discord_query.rules[1].invert === true &&
    contains(discord_query.rules[1].source_ip_cidr, "192.0.2.133/32"),
    "1.14 Discord DNS must preserve device exclusion in the domain query rule");
let evaluate_index = index(value, r => r.action == "evaluate" && r.server == "dnsmasq-server" && domain_rule(r));
let respond_index = index(value, r => r.action == "respond" && r.type == "logical" && domain_rule(r));
let fallback_index = index(value, r => r.action == "route" && r.server == "dns-server" && domain_rule(r));
assert(evaluate_index >= 0, "1.14 must evaluate the dnsmasq response");
assert(respond_index > evaluate_index, "1.14 must respond only after dnsmasq evaluate");
assert(fallback_index > respond_index, "1.14 fallback must run only after rejected dnsmasq response");
let respond = rules(value)[respond_index];
assert(respond.server == null, "1.14 respond must return the evaluated response, not query another server");
assert(respond.rules[1].match_response === true && respond.rules[1].invert === true, "1.14 response filter must inspect the evaluated non-FakeIP response");
assert(find(value, r => r.action == "evaluate" && r.server == "dns-server" && domain_rule(r)) == null, "1.14 must not evaluate the fallback resolver before dnsmasq");
' || fail "DNS 1.12/1.13/1.14 semantic chain assertion failed"

printf 'sing-box DNS 1.14 semantic generation checks passed\n'
