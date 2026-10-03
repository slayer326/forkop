#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ucode -L "$LIB" -e '
let ip = require("core.ip");
let matchers = ip.discord_voice_port_matchers();
if (index(matchers.port, 443) < 0 || index(matchers.port, 3478) < 0)
    exit(1);
for (let expected in ["5000:5020", "19294:19344", "50000:65535"])
    if (index(matchers.port_range, expected) < 0)
        exit(1);
let normalized = [];
for (let port in matchers.port)
    push(normalized, "" + port);
for (let range in matchers.port_range)
    push(normalized, replace(range, ":", "-"));
for (let item in split(ip.DISCORD_VOICE_PORTS_NFT, ","))
    if (index(normalized, item) < 0)
        exit(1);
' || { echo 'Discord nftables and sing-box ports differ' >&2; exit 1; }

cat >"$work/fixture.json" <<'JSON'
{
  "settings": { ".name":"settings", ".type":"settings", "dns_server":"77.88.8.8" },
  "section": [{
    ".name":"voice", ".type":"section", ".index":"0", "enabled":"1", "action":"connection",
    "outbound_jsons":["{\"type\":\"http\",\"tag\":\"up\",\"server\":\"proxy.example\",\"server_port\":8080}"],
    "community_lists":["discord"], "port":["80"]
  }]
}
JSON

ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
  "$work/fixture.json" "$work/config.json" 192.0.2.1 0 1 '' 1.14.1 >/dev/null

ucode -L "$LIB" -e '
let ip = require("core.ip");
let config = json(require("fs").readfile(ARGV[0]));
let found = [];
for (let rule in config.route.rules) {
    if (rule.network == "udp" && type(rule.ip_cidr) == "array" &&
        sprintf("%J", rule.ip_cidr) == sprintf("%J", ip.CLOUDFLARE_SHARED_CIDRS))
        push(found, rule);
}
if (length(found) != 1)
    exit(1);
let rule = found[0];
if (rule.outbound != "voice-out" || index(rule.port, 80) >= 0)
    exit(1);
let expected = ip.discord_voice_port_matchers();
for (let key in expected)
    if (sprintf("%J", rule[key]) != sprintf("%J", expected[key]))
        exit(1);
' "$work/config.json" || { echo 'Discord shared Cloudflare route is not aligned with interception' >&2; exit 1; }

echo 'Discord route alignment checks passed'
