#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc evaluates logical rules as far as the target allows
# instead of refusing them all: a decided "no" of any child settles an AND
# (a decided "match" settles an OR), so a section whose devices exclusions
# wrap its conditions in a logical rule no longer hides the route of every
# other target. An undecidable child still makes the combination undecidable
# unless another child settles it; the first undecidable child's reason (and
# its source list) is reported. Asked "for the devices of the rule"
# (assume_rule_source), an inverted source list is satisfied by assumption —
# its addresses are the EXCLUDED devices, none can stand in for a covered one.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

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
let t = r.target(c.host, c.ip || "", { fakeip: c.fakeip == true, network: c.network || "tcp", port: c.port || 443,
    source: c.source || "", assume_rule_source: c.assume == true });
let config = { route: { final: "direct-out", rule_set: c.rule_set || [], rules: c.rules },
    outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "main-out" }, { type: "vless", tag: "youtube-out" } ] };
let got = r.resolve(config, sections, t);
print(sprintf("%J\n", { status: got.status, reason: got.reason, rule: got.route_rule, section: got.section, kind: got.kind, source_scope: got.source_scope }));
EOF

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

resolve() {
    printf '%s' "$2" >"$WORK/$1.json"
    FORKOP_LIB="$LIB" ucode -L "$LIB" "$WORK/resolve.uc" "$WORK/forkop" "$WORK/$1.json"
}
expect() { # name json want
    local got
    got="$(resolve "$1" "$2")"
    [ "$got" = "$3" ] || fail "$1: got $got, want $3"
}

# A section with an excluded device: the generator wraps its conditions in a
# logical AND with an inverted source_ip_cidr child.
wrapper='{ "action": "route", "inbound": [ "tproxy-in" ], "type": "logical", "mode": "and",
  "rules": [ { "domain_suffix": [ "youtube.com" ] }, { "source_ip_cidr": [ "192.168.1.10/32" ], "invert": true } ],
  "outbound": "youtube-out" }'
plain='{ "action": "route", "inbound": [ "tproxy-in" ], "domain_suffix": [ "example.org" ], "outbound": "main-out" }'

# A target outside the wrapper falls through to the rule below.
expect below "{ \"host\": \"example.org\", \"rules\": [ $wrapper, $plain ] }" \
    '{ "status": "decided", "reason": null, "rule": 1, "section": "main", "kind": "rule", "source_scope": null }'

# A target the wrapper alone could take is source-scoped: not guessed.
expect scoped "{ \"host\": \"youtube.com\", \"rules\": [ $wrapper, $plain ] }" \
    '{ "status": "undecidable", "reason": "source_scoped_rule", "rule": 0, "section": null, "kind": null, "source_scope": null }'

# Asked for the devices of the rule: decided, and the answer says so. The
# excluded address must NOT be named as the assumed source.
expect assumed "{ \"host\": \"youtube.com\", \"assume\": true, \"rules\": [ $wrapper, $plain ] }" \
    '{ "status": "decided", "reason": null, "rule": 0, "section": "youtube", "kind": "rule", "source_scope": { "source": null, "assumed": true } }'

# The excluded device itself falls through; any other device takes the wrapper.
expect excluded "{ \"host\": \"youtube.com\", \"source\": \"192.168.1.10\", \"rules\": [ $wrapper, $plain ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct", "source_scope": null }'
expect covered "{ \"host\": \"youtube.com\", \"source\": \"192.168.1.20\", \"rules\": [ $wrapper, $plain ] }" \
    '{ "status": "decided", "reason": null, "rule": 0, "section": "youtube", "kind": "rule", "source_scope": { "source": "192.168.1.20", "assumed": false } }'

# OR: one decided "match" settles the combination; none matching is a "no".
orwrap='{ "action": "route", "inbound": [ "tproxy-in" ], "type": "logical", "mode": "or",
  "rules": [ { "domain_suffix": [ "youtube.com" ] }, { "domain_suffix": [ "video.com" ] } ], "outbound": "youtube-out" }'
expect or_hit "{ \"host\": \"video.com\", \"rules\": [ $orwrap ] }" \
    '{ "status": "decided", "reason": null, "rule": 0, "section": "youtube", "kind": "rule", "source_scope": null }'
expect or_miss "{ \"host\": \"nothing.test\", \"rules\": [ $orwrap ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct", "source_scope": null }'

# An empty logical rule is not guessed (it could hide every rule below).
empty='{ "action": "route", "inbound": [ "tproxy-in" ], "type": "logical", "mode": "and", "rules": [], "outbound": "youtube-out" }'
expect empty "{ \"host\": \"youtube.com\", \"rules\": [ $empty ] }" \
    '{ "status": "unsupported", "reason": "logical_rule", "rule": 0, "section": null, "kind": null, "source_scope": null }'

# A child that cannot be decided keeps the wrapper undecidable when no
# sibling settles it; the reason is the child's, not a generic one.
regex_child='{ "action": "route", "inbound": [ "tproxy-in" ], "type": "logical", "mode": "and",
  "rules": [ { "domain_suffix": [ "youtube.com" ] }, { "domain_regex": [ "tube" ] } ], "outbound": "youtube-out" }'
expect undecidable_child "{ \"host\": \"youtube.com\", \"rules\": [ $regex_child ] }" \
    '{ "status": "undecidable", "reason": "undecidable_matcher", "rule": 0, "section": null, "kind": null, "source_scope": null }'
# ...but a decided "no" of a sibling settles the AND anyway.
expect settled_and "{ \"host\": \"other.test\", \"rules\": [ $regex_child ] }" \
    '{ "status": "decided", "reason": null, "rule": null, "section": null, "kind": "direct", "source_scope": null }'

echo "routing_resolve_logical: ok"
