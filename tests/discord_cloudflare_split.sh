#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
NFT_APPLY_UC="$FORKOP_LIB/nft/apply.uc"
IP_UC="$FORKOP_LIB/core/ip.uc"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The Discord community subnet list also carries shared Cloudflare Anycast
# ranges. Routed as ordinary destination subnets they capture large amounts of
# unrelated traffic, torrents included. They must reach nftables only through
# Discord's own UDP media ports, while Discord's dedicated networks keep the
# ordinary treatment.

ucode -L "$FORKOP_LIB" -e '
let ip = require("core.ip");

// Shared Cloudflare ranges are recognised, Discord-owned ones are not.
for (let value in [ "104.16.0.0/12", "162.159.0.0/16", "2606:4700::/32" ])
    if (!ip.is_cloudflare_shared_cidr(value)) {
        warn("shared Cloudflare range not recognised: " + value + "\n");
        exit(1);
    }
for (let value in [ "66.22.192.0/18", "35.214.0.0/16", "1.2.3.4/32", "" ])
    if (ip.is_cloudflare_shared_cidr(value)) {
        warn("non-Cloudflare range wrongly classified: " + value + "\n");
        exit(1);
    }
// Matching must not depend on letter case in the IPv6 forms.
if (!ip.is_cloudflare_shared_cidr("2606:4700::/32") || !ip.is_cloudflare_shared_cidr("2606:4700::/32"))
    exit(1);
// Discord media ports cover voice, video and the STUN port.
for (let part in [ "3478", "50000-65535", "5000-5020", "19294-19344" ])
    if (index(ip.DISCORD_VOICE_PORTS_NFT, part) < 0) {
        warn("missing Discord media port range: " + part + "\n");
        exit(1);
    }
' || fail "core/ip.uc must classify shared Cloudflare ranges and Discord media ports"

# The split itself is a source contract: the shared ranges must go to the
# UDP-scoped sets, never to the plain subnet sets.
awk '
  /^function nft_add_community_subnet_file_for_section\(/ { inside = 1 }
  inside && /nft_community_subnet_lines\(filepath, service, true\)/  { shared = NR }
  inside && /nft_community_subnet_lines\(filepath, service, false\)/ { dedicated = NR }
  inside && /sets\.udp_ip_ports, sets\.udp_ip6_ports/ { udp = NR }
  inside && /DISCORD_VOICE_PORTS_NFT/ { ports = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && shared && dedicated && udp && ports && udp > shared ? 0 : 1 }
' "$NFT_APPLY_UC" || fail "shared Cloudflare ranges must be added to the UDP port sets with the Discord media ports"

# Any other service keeps the untouched path, so the dedicated Cloudflare list
# is not silently narrowed along with Discord.
grep -Fq 'if (as_string(service) != "discord")' "$NFT_APPLY_UC" ||
  fail "only the Discord list may be split"

# The narrowed rules must exist only when the section really enables Discord.
awk '
  /^function section_priority_needs_udp_ip_port_rules\(/ { inside = 1 }
  inside && /"discord"/ { matched = NR }
  inside && /^}/ { done = 1; exit }
  END { exit done && matched ? 0 : 1 }
' "$NFT_APPLY_UC" || fail "the UDP-scoped rules must be gated on the Discord list"

grep -Fq 'udp_ip_ports: prefix + "_udp_ip_ports"' "$NFT_APPLY_UC" ||
  fail "each section needs its own UDP-scoped ip/port sets"
grep -Fq 'nft_create_ipv4_port_set(table, sets.udp_ip_ports)' "$NFT_APPLY_UC" ||
  fail "the UDP-scoped sets must be created with the other priority sets"

grep -Fq 'CLOUDFLARE_SHARED_CIDRS' "$IP_UC" ||
  fail "the shared Cloudflare ranges must stay in one place"

# Interception is only half of it. A packet that nftables redirects into
# sing-box and that matches no route rule falls through to route.final, which
# is direct: it leaves the router outside the section the user chose. The
# community rule-set does not cover every intercepted port, so the generator
# emits the matching route rule, and both halves come from one list of ports.
ucode -L "$FORKOP_LIB" -e '
let ip = require("core.ip");

// Both halves, normalised to sorted "first-last" pairs.
function nft_ports() {
    let set = [];
    for (let part in split(ip.DISCORD_VOICE_PORTS_NFT, ",")) {
        let span = split(part, "-");
        push(set, length(span) == 2
            ? sprintf("%05d-%05d", int(span[0]), int(span[1]))
            : sprintf("%05d-%05d", int(part), int(part)));
    }
    return join(" ", sort(set));
}
function matcher_ports() {
    let matchers = ip.discord_voice_port_matchers();
    let set = [];
    for (let port in matchers.port ?? [])
        push(set, sprintf("%05d-%05d", int(port), int(port)));
    for (let span in matchers.port_range ?? []) {
        let parts = split(span, ":");
        push(set, sprintf("%05d-%05d", int(parts[0]), int(parts[1])));
    }
    return join(" ", sort(set));
}
if (nft_ports() != matcher_ports()) {
    warn("the intercepted and the routed Discord ports differ:\n  nftables: " +
        nft_ports() + "\n  sing-box: " + matcher_ports() + "\n");
    exit(1);
}
if (length(ip.DISCORD_VOICE_PORT_RANGES) < 4) {
    warn("the Discord media port ranges are incomplete\n");
    exit(1);
}
' || fail "the nftables ports and the sing-box port matchers must describe the same ports"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name":"settings", ".type":"settings", "dns_server":"77.88.8.8" },
  "section": [
    {
      ".name":"voice", ".type":"section", ".index":"0", "enabled":"1", "action":"connection",
      "outbound_jsons":["{\"type\":\"http\",\"tag\":\"up\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "community_lists":["discord"], "port":["80"]
    },
    {
      ".name":"other", ".type":"section", ".index":"1", "enabled":"1", "action":"connection",
      "outbound_jsons":["{\"type\":\"http\",\"tag\":\"up2\",\"server\":\"proxy.example\",\"server_port\":8081}"],
      "community_lists":["youtube"]
    }
  ]
}
JSON

ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/generator.uc" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" 192.0.2.1 0 1 '' 1.14.1 ||
  fail "the generator must accept a section with the Discord list"

ucode -L "$FORKOP_LIB" -e '
let ip = require("core.ip");
let config = json(require("fs").readfile(ARGV[0]));

function shared_rules(outbound) {
    let found = [];
    for (let rule in config.route.rules) {
        if (rule.network != "udp" || type(rule.ip_cidr) != "array")
            continue;
        if (index(sprintf("%J", rule.ip_cidr), "162.158.0.0/15") < 0)
            continue;
        if ((rule.outbound ?? "") == outbound)
            push(found, rule);
    }
    return found;
}

// The section that enables the list gets the rule, for the ranges and the
// ports nftables intercepts, routed to that section.
let voice = shared_rules("voice-out");
if (length(voice) != 1) {
    warn("expected one shared-Cloudflare route rule for the section, got " +
        length(voice) + "\n");
    exit(1);
}
let rule = voice[0];
if (sprintf("%J", rule.ip_cidr) != sprintf("%J", ip.CLOUDFLARE_SHARED_CIDRS)) {
    warn("the routed ranges differ from the intercepted ones\n");
    exit(1);
}
let matchers = ip.discord_voice_port_matchers();
for (let key in matchers)
    if (sprintf("%J", rule[key]) != sprintf("%J", matchers[key])) {
        warn("route rule " + key + " is " + sprintf("%J", rule[key]) +
            ", expected " + sprintf("%J", matchers[key]) + "\n");
        exit(1);
    }
// The section port filter must not narrow it: nftables keys the shared ranges
// by the Discord ports alone.
if (index(sprintf("%J", rule.port), "80") >= 0) {
    warn("the section port filter must not apply to the shared ranges\n");
    exit(1);
}
if (rule.action != "route") {
    warn("the rule must route, not something else\n");
    exit(1);
}

// A section without the list gets no such rule.
if (length(shared_rules("other-out")) != 0) {
    warn("a section without the Discord list must not route the shared ranges\n");
    exit(1);
}
' "$WORK_DIR/config.json" ||
  fail "the generator must route exactly what nftables intercepts for Discord"

printf 'discord cloudflare split checks passed\n'
