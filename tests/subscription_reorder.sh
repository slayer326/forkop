#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat >"$WORK_DIR/reorder.uc" <<'UCODE'
let fs = require("fs");
let parser = require("subscription.parser");
let folder = getenv("FORKOP_REORDER_TEST_DIR");
let left = folder + "/left.json", right = folder + "/right.json";
let a = {type: "vless", tag: "A", server: "a.example", server_port: 443, uuid: "first"};
let b = {type: "vless", tag: "B", server: "b.example", server_port: 443, uuid: "second"};
let group = {type: "urltest", tag: "Group", outbounds: ["A", "B"]};
function write(path, outbounds) { fs.writefile(path, sprintf("%J", {outbounds})); }
function expect(equal, label) {
    if (parser.runtime_outbounds_equal(left, right) != equal)
        die(label + "\n");
}
write(left, [a, b, group]);
write(right, [group, b, a]);
expect(true, "top-level provider reordering must not request a reload");
group.outbounds = ["B", "A"];
write(right, [group, b, a]);
expect(false, "nested group order must remain significant");
group.outbounds = ["A", "B"];
b.uuid = "changed";
write(right, [group, b, a]);
expect(false, "changed credentials must request a reload");
b.uuid = "second";
write(right, [group, b, a, a]);
expect(false, "changed duplicate counts must remain significant");
write(right, [group, a]);
expect(false, "removed servers must request a reload");
print("subscription reorder checks passed\n");
UCODE
FORKOP_REORDER_TEST_DIR="$WORK_DIR" ucode -L "$ROOT_DIR/forkop/files/usr/lib" "$WORK_DIR/reorder.uc"
