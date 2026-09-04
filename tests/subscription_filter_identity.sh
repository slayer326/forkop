#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ucode -L "$ROOT_DIR/forkop/files/usr/lib" -e '
let identity = require("subscription.filter_identity");
function check(ok, message) { if (!ok) die(message + "\n"); }
let before = { type: "vless", server: "example.com", server_port: 443,
    uuid: "secret", tag: "Old", remark: "Old name", tls: { enabled: true } };
let after = { tls: { enabled: true }, uuid: "secret", server_port: 443,
    server: "example.com", type: "vless", tag: "New", remark: "New name",
    __forkop_filter_names: [ "provider injected alias" ] };
check(identity.connection_key(before) == identity.connection_key(after), "renames must preserve identity");
let next = identity.inherit_names({ outbounds: [ before ] }, { outbounds: [ after ] });
let names = identity.names(next.outbounds[0]);
check(index(names, "Old name") >= 0 && index(names, "Old") >= 0, "old names must remain usable for filters");
check(index(names, "provider injected alias") < 0, "provider must not control alias history");
after.uuid = "different-secret";
next = identity.inherit_names({ outbounds: [ before ] }, { outbounds: [ after ] });
check(index(identity.names(next.outbounds[0]), "Old") < 0, "changed connections must not inherit names");
check(identity.connection_key({ type: "selector", tag: "Group" }) == "", "groups have no connection identity");
print("subscription filter identity checks passed\n");
'
