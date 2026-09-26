#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

source = (pathlib.Path(sys.argv[1]) / 'forkop/files/usr/lib/components/action.uc').read_text()
match = re.search(r'^function component_action\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
if match is None:
    raise SystemExit('missing component_action')
probe = r'''
let scenario = ARGV[0];
let loaded_version = scenario == "fresh" ? "1.0.0" : "1.1.0";
let installed_version = loaded_version;
let marker = scenario != "fresh";
let running = false;
let recovery_error = scenario == "failed" ? "rollback failed" : "";
let continued = false;
function as_string(value) { return value == null ? "" : "" + value; }
function normalize_component_name(value) { return value; }
function acquire_component_lock() { return true; }
function init_tmp_dir() { return true; }
function is_apk() { return false; }
function file_exists(path) { return marker; }
function capture_forkop_running_state() {}
function recover_forkop_opkg_set() {
    if (recovery_error != "") return recovery_error;
    installed_version = "1.0.0";
    running = true;
    marker = false;
    return "";
}
function installed_package_version(name) { return installed_version; }
function action_success(component, action, message, current, latest, changed, status) {
    print(sprintf("%J\n", { success: true, message, current, changed, status, marker, running, continued }));
    exit(0);
}
function action_fail(component, action, message) {
    print(sprintf("%J\n", { success: false, message, marker, running, continued }));
    exit(1);
}
function install_forkop() {
    continued = true;
    if (loaded_version != installed_version)
        action_fail("forkop", "install", "Installed Forkop package versions are inconsistent");
    action_success("forkop", "install", "Forkop has been installed", installed_version, "", 1, "latest");
}
'''
probe += '\n' + match.group() + '\ncomponent_action("forkop", "install");\n'
pathlib.Path(sys.argv[2]).write_text(probe)
PY

ucode "$WORK_DIR/probe.uc" recovered > "$WORK_DIR/recovered.json" || true
ucode "$WORK_DIR/probe.uc" fresh > "$WORK_DIR/fresh.json"
ucode "$WORK_DIR/probe.uc" failed > "$WORK_DIR/failed.json" || true
python3 - "$WORK_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
recovered = json.loads((root / 'recovered.json').read_text())
fresh = json.loads((root / 'fresh.json').read_text())
failed = json.loads((root / 'failed.json').read_text())
assert recovered['success'] and recovered['status'] == 'recovered'
assert 'fresh invocation' in recovered['message']
assert recovered['current'] == '1.0.0' and recovered['changed'] == 0
assert not recovered['continued'] and not recovered['marker'] and recovered['running']
assert fresh['success'] and fresh['status'] == 'latest' and fresh['continued']
assert not failed['success'] and 'rollback failed' in failed['message']
assert failed['marker'] and not failed['continued']
print('Forkop recovery boundary checks passed')
PY
