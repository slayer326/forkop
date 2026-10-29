#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc decides a rule_set matcher by asking sing-box itself
# ("sing-box rule-set match") about the local list file the generated config
# names. A list it cannot ask about (remote, missing file, failing command,
# a target that is not a plain host/address) stays undecidable: never guessed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Stub of "sing-box rule-set match -f <format> <path> <value>": a list file
# holds one matching value per line; "!fail" makes the command fail. Like
# sing-box, it prints the answer through its logger, on stderr; a miss may
# still print a warning that mentions matching.
cat >"$WORK/sing-box" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK/calls"
[ "\$1 \$2 \$3" = "rule-set match -f" ] || exit 2
[ "\$4" = binary ] || [ "\$4" = source ] || exit 2
grep -qx '!fail' "\$5" && { echo "FATAL read rule-set" >&2; exit 1; }
grep -qxF "\$6" "\$5" && { echo "match rules.[0]: domain/domain_suffix=<binary>" >&2; exit 0; }
echo "WARN[0000] no rule-set rule to match" >&2
exit 0
EOF
chmod +x "$WORK/sing-box"
export FORKOP_RULESET_MATCH_BIN="$WORK/sing-box"

printf 'youtube.com\nwww.youtube.com\n' >"$WORK/youtube.srs"
printf 'example.org\n' >"$WORK/other.srs"
printf '203.0.113.7\n' >"$WORK/addresses.srs"
printf '!fail\n' >"$WORK/broken.srs"

cat >"$WORK/forkop" <<'EOF'
config settings 'settings'
config section 'youtube'
	option action 'connection'
config section 'main'
	option action 'connection'
EOF

cat >"$WORK/resolve.uc" <<'EOF'
let fs = require("fs"), r = require("routing.resolve");
let sections = r.parse_config(fs.readfile(ARGV[0]));
let c = json(fs.readfile(ARGV[1]));
let t = r.target(c.host, c.ip || "198.18.0.9", { fakeip: c.fakeip != false });
let config = { route: { final: "direct-out", rule_set: c.rule_set, rules: c.rules },
    outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "main-out" },
        { type: "vless", tag: "youtube-out" } ] };
let got = r.resolve(config, sections, t);
print(sprintf("%J\n", { status: got.status, reason: got.reason, rule: got.route_rule, section: got.section, kind: got.kind }));
EOF

# case <name> <json> -> prints the compact result
resolve() {
    printf '%s' "$2" >"$WORK/$1.json"
    : >"$WORK/calls"
    FORKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/resolve.uc" "$WORK/forkop" "$WORK/$1.json"
}
expect() { # name json want
    local got
    got="$(resolve "$1" "$2")"
    [ "$got" = "$3" ] || fail "$1: got $got, want $3"
}

sets="[ { \"type\": \"local\", \"tag\": \"yt\", \"format\": \"binary\", \"path\": \"$WORK/youtube.srs\" },
  { \"type\": \"local\", \"tag\": \"other\", \"format\": \"binary\", \"path\": \"$WORK/other.srs\" },
  { \"type\": \"local\", \"tag\": \"addresses\", \"format\": \"source\", \"path\": \"$WORK/addresses.srs\" },
  { \"type\": \"local\", \"tag\": \"broken\", \"format\": \"binary\", \"path\": \"$WORK/broken.srs\" },
  { \"type\": \"local\", \"tag\": \"absent\", \"format\": \"binary\", \"path\": \"$WORK/absent.srs\" },
  { \"type\": \"remote\", \"tag\": \"remote\", \"format\": \"binary\", \"url\": \"https://lists.invalid/x.srs\" } ]"
yt='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": "yt", "outbound": "youtube-out" }'
other='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "other" ], "outbound": "main-out" }'
youtube='{ "status": "decided", "reason": null, "rule": 0, "section": "youtube", "kind": "rule" }'

# A list that holds the host decides the rule.
expect list_hit "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $yt ] }" "$youtube"
grep -qx "rule-set match -f binary $WORK/youtube.srs youtube.com" "$WORK/calls" || fail "list_hit: sing-box was not asked"

# A list above the owner that does not hold the host no longer hides it.
expect list_miss_above "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": 1, "section": "youtube", "kind": "rule" }'

# First match still wins: the list above holds the host.
expect list_hit_above "{ \"host\": \"example.org\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": 0, "section": "main", "kind": "rule" }'

# No list holds it: the final outbound.
expect list_miss_all "{ \"host\": \"nothing.test\", \"rule_set\": $sets, \"rules\": [ $other, $yt ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct" }'

# One rule, several lists: any of them matches; asking stops at the first hit.
many='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": [ "yt", "broken" ], "outbound": "youtube-out" }'
expect list_any "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $many ] }" "$youtube"
[ "$(wc -l <"$WORK/calls")" = 1 ] || fail "list_any: lists after the hit were asked"

# A static matcher hit needs no list at all.
mixed='{ "action": "route", "inbound": [ "tproxy-in" ], "domain_suffix": [ "youtube.com" ], "rule_set": [ "broken" ], "outbound": "youtube-out" }'
expect static_hit "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $mixed ] }" "$youtube"
[ ! -s "$WORK/calls" ] || fail "static_hit: a list was asked although a static matcher decided"

# A real-address connection is matched by the address as well as the host.
addr='{ "action": "route", "inbound": [ "tproxy-in" ], "rule_set": "addresses", "outbound": "youtube-out" }'
expect address_hit "{ \"host\": \"plain.test\", \"ip\": \"203.0.113.7\", \"fakeip\": false, \"rule_set\": $sets, \"rules\": [ $addr ] }" "$youtube"
grep -qx "rule-set match -f source $WORK/addresses.srs 203.0.113.7" "$WORK/calls" || fail "address_hit: the address was not asked"
# A FakeIP connection reaches sing-box as the name: its address is not asked.
expect fakeip_address "{ \"host\": \"plain.test\", \"ip\": \"198.18.0.9\", \"rule_set\": $sets, \"rules\": [ $addr ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct" }'
! grep -q '198\.18\.0\.9' "$WORK/calls" || fail "fakeip_address: the FakeIP address was asked"

# Undecidable, never guessed.
undecided='{ "status": "undecidable", "reason": "undecidable_matcher", "rule": 0, "section": null, "kind": null }'
for tag in broken absent remote undeclared; do
    rule="{ \"action\": \"route\", \"inbound\": [ \"tproxy-in\" ], \"rule_set\": \"$tag\", \"outbound\": \"youtube-out\" }"
    expect "unknown_$tag" "{ \"host\": \"youtube.com\", \"rule_set\": $sets, \"rules\": [ $rule ] }" "$undecided"
done
# A host that is not a plain name is never handed to a shell command.
expect unsafe_host "{ \"host\": \"you\$(id)tube.com\", \"rule_set\": $sets, \"rules\": [ $yt ] }" "$undecided"
[ ! -s "$WORK/calls" ] || fail "unsafe_host: sing-box was called"
# No list declaration at all (older callers): as before.
expect no_declaration "{ \"host\": \"youtube.com\", \"rules\": [ $yt ] }" "$undecided"

echo "routing_resolve_rule_set: ok"
