#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/forkop/files/usr/lib" -e '
let prune = require("singbox.prune");
function check(ok, message) { if (!ok) die(message + "\n"); }
function has(config, tag) {
    for (let outbound in config.outbounds)
        if (outbound.tag == tag) return true;
    return false;
}
let config = {
    outbounds: [
        { type: "vless", tag: "kept", server: "kept.example" },
        { type: "vless", tag: "excluded", server: "excluded.example" },
        { type: "vless", tag: "detour", server: "detour.example" },
        { type: "vless", tag: "dns-transport", server: "dns.example" },
        { type: "vless", tag: "route-transport", server: "route.example" },
        { type: "vless", tag: "unselected-leaf", server: "leaf.example" },
        { type: "selector", tag: "unselected-provider-group", outbounds: [ "unselected-leaf" ] },
        { type: "selector", tag: "selected-provider-group", outbounds: [ "kept" ] },
        { type: "selector", tag: "main", outbounds: [ "selected-provider-group", "detour" ], default: "selected-provider-group" },
        { type: "vless", tag: "manual", server: "manual.example", detour: "detour" }
    ],
    route: { final: "main", rules: [ { outbound: "route-transport" } ] },
    dns: { servers: [ { tag: "remote-dns", detour: "dns-transport" } ] }
};
let candidates = {};
for (let tag in [ "kept", "excluded", "detour", "dns-transport", "route-transport",
    "unselected-leaf", "unselected-provider-group", "selected-provider-group" ])
    candidates[tag] = true;
let removed = prune.unused_outbounds(config, candidates);
check(length(removed) == 3, "only three unused subscription outbounds must be removed");
check(!has(config, "excluded"), "a filtered leaf must not reach sing-box");
check(!has(config, "unselected-provider-group") && !has(config, "unselected-leaf"),
    "unreachable provider groups must not retain filtered leaves");
for (let tag in [ "kept", "detour", "dns-transport", "route-transport", "selected-provider-group", "main", "manual" ])
    check(has(config, tag), "required outbound lost: " + tag);
let fallback = { outbounds: [
    { type: "vless", tag: "a" }, { type: "vless", tag: "b" },
    { type: "selector", tag: "main", outbounds: [ "a", "b" ] }
] };
check(length(prune.unused_outbounds(fallback, { a: true, b: true })) == 0,
    "the unfiltered selector fallback must retain every server");
print("subscription outbound pruning checks passed\n");
'
