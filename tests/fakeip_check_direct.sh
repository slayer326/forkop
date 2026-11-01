#!/usr/bin/env bash
set -euo pipefail
# The FakeIP check leaves the router directly. The diagnostics compare its
# public IP with the proxy check's; a section that catches every address
# made both leave through the VPN and reported the same IP.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1"
  },
  "section": [
    {
      ".name": "everything",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"socks\",\"server\":\"192.0.2.1\",\"server_port\":1080}" ],
      "ip_cidr": [ "0.0.0.0/0" ],
      "domain_suffix": [ "example" ]
    }
  ]
}
JSON

output="$WORK_DIR/config.json"
mkdir -p "$output.section-cache" "$output.rulesets"
ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1" "" "1.14.4" >"$WORK_DIR/generate.log" 2>&1 ||
  { cat "$WORK_DIR/generate.log" >&2; fail "generation failed"; }

ucode -e '
let rules = json(require("fs").readfile(ARGV[0])).route.rules;
let check = -1, proxy = -1, section = -1;
for (let i = 0; i < length(rules); i++) {
    let rule = rules[i];
    if (rule.domain == "fakeip.podkop.fyi" && check < 0) check = i;
    if (rule.domain == "ip.podkop.fyi" && proxy < 0) proxy = i;
    if (type(rule.ip_cidr) == "array" && index(rule.ip_cidr, "0.0.0.0/0") >= 0 && section < 0) section = i;
}
if (check < 0) die("the FakeIP check has no route rule\n");
let rule = rules[check];
if (rule.action != "route" || rule.outbound != "direct-out")
    die("the FakeIP check is not routed directly: " + sprintf("%J", rule) + "\n");
if (rule.override_port != 8443)
    die("the FakeIP check lost its port\n");
if (proxy < 0 || rules[proxy].outbound == "direct-out")
    die("the proxy check no longer leaves through the section\n");
if (section >= 0 && section < check)
    die("a section rule comes before the FakeIP check\n");
' "$output" || fail "the FakeIP check can leave through a section"

printf 'The FakeIP check leaves the router directly\n'
