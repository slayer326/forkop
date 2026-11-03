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
let tags = [ "same-connection", "new-connection" ];
let display = { "same-connection": "New name", "new-connection": "Old name" };
let aliases = { "same-connection": [ "Old name" ], "new-connection": [] };
let owners = identity.preferred_name_owners(tags, display, aliases, [ "Old name" ]);
check(identity.preferred_name_matches(tags[0], display[tags[0]], aliases[tags[0]], [ "Old name" ], owners),
    "the original connection must retain the old-name filter");
check(!identity.preferred_name_matches(tags[1], display[tags[1]], aliases[tags[1]], [ "Old name" ], owners),
    "a different connection reusing the old name must not enter the filter");
owners = identity.preferred_name_owners(tags, display, aliases, [ "New name" ]);
check(identity.preferred_name_matches(tags[0], display[tags[0]], aliases[tags[0]], [ "New name" ], owners),
    "current names must still match without a competing inherited alias");
check(identity.connection_key({ type: "selector", tag: "Group" }) == "", "groups have no connection identity");
// A provider may switch the endpoint address (domain <-> IP) without renaming
// the node: aliases must follow when everything else matches exactly once.
let moved = { tls: { enabled: true }, uuid: "secret", server_port: 443,
    server: "203.0.113.10", type: "vless", tag: "Old", remark: "Old name" };
let moved_next = identity.inherit_names({ outbounds: [ before ] }, { outbounds: [ moved ] });
check(type(moved_next.outbounds[0].__forkop_filter_names) == "array" &&
    index(moved_next.outbounds[0].__forkop_filter_names, "Old name") >= 0,
    "address-only change must inherit the old filter names");
// Ambiguous duplicates (two identical profiles) must not inherit anything.
let dup_next = identity.inherit_names({ outbounds: [ before ] },
    { outbounds: [ moved, { tls: { enabled: true }, uuid: "secret", server_port: 443,
        server: "198.51.100.20", type: "vless", tag: "Copy", remark: "Old name" } ] });
check(dup_next.outbounds[0].__forkop_filter_names == null &&
    dup_next.outbounds[1].__forkop_filter_names == null,
    "ambiguous address migration must not inherit names");
// A renamed node at a new address is a different node: no migration.
let renamed_moved = { tls: { enabled: true }, uuid: "secret", server_port: 443,
    server: "203.0.113.10", type: "vless", tag: "New", remark: "New name" };
let renamed_next = identity.inherit_names({ outbounds: [ before ] }, { outbounds: [ renamed_moved ] });
check(renamed_next.outbounds[0].__forkop_filter_names == null,
    "simultaneous rename and address change must not inherit names");
// A changed credential is a different node even at a new address.
moved.uuid = "different-secret";
let changed_next = identity.inherit_names({ outbounds: [ before ] }, { outbounds: [ moved ] });
check(changed_next.outbounds[0].__forkop_filter_names == null,
    "address change with different credentials must not inherit names");
print("subscription filter identity checks passed\n");
'
