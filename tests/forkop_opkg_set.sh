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
names = ('forkop_release_matches', 'opkg_forkop_set_versions_match',
         'opkg_forkop_set_command', 'opkg_forkop_recovery_files',
         'restore_forkop_opkg_service', 'finish_forkop_opkg_recovery',
         'recover_forkop_opkg_set', 'install_forkop_opkg_set')
functions = []
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    functions.append(match.group())

prefix = r'''
const FORKOP_VERSION = "1.0.0";
const FORKOP_OPKG_RECOVERY_DIR = "/recovery";
const SERVICE_INIT = "/init";
let tmp_dir = "/tmp";
let forkop_was_running = true;
let service_running = true;
let service_restart_fail = false;
let versions = {};
let failure = "";
let uncommitted = "";
let rollback_failure = "";
let events = [];
let downloads = [];
let recovery_dir = false;
let marker = "";
let marker_tmp = "";
function file_exists(path) { return path == FORKOP_OPKG_RECOVERY_DIR ? recovery_dir : marker != ""; }
function file_nonempty(path) { return index(downloads, path) >= 0; }
function read_file(path) { return marker; }
function write_file(path, value) { marker_tmp = value; return true; }
let fs = { rename: function(source, target) { marker = marker_tmp; marker_tmp = ""; return true; } };
function command_success_from_args(args) {
    if (args[0] == "mkdir") { recovery_dir = true; return true; }
    if (args[0] == "rm") { recovery_dir = false; marker = ""; downloads = []; return true; }
    if (args[0] == "sync") return true;
    if (args[0] == SERVICE_INIT) {
        if (args[1] == "status") return service_running;
        if (args[1] == "stop") { service_running = false; return true; }
        if (args[1] == "start" || args[1] == "restart") {
            if (service_restart_fail) return false;
            service_running = true;
            return true;
        }
    }
    check(false, "unexpected filesystem command");
}
function check(ok, message) { if (!ok) { warn("FAIL: " + message + "\n"); exit(1); } }
function installed_package_version(name) { return versions[name] || ""; }
function forkop_status_running_with_timeout() { return service_running; }
function previous_forkop_release(version) {
    check(version == FORKOP_VERSION, "wrong previous release");
    return { backend_name: "forkop_1.0.0.ipk", backend_url: "old-backend",
        app_name: "luci-app-forkop_1.0.0.ipk", app_url: "old-app",
        i18n_name: "luci-i18n-forkop-ru_1.0.0.ipk", i18n_url: "old-i18n" };
}
function download_with_retry(url, path, label) { push(downloads, path); return true; }
function command_from_args(args) { return join(" ", args); }
function command_output_from_args(args) { check(args[0] == "dirname", "unexpected path command"); return "/"; }
function ensure_dir(path) { return path == "/"; }
function path_basename(path) { let parts = split(path, "/"); return parts[length(parts) - 1]; }
function updates_log(message, level) { push(events, message); }
function run_logged(description, command) {
    push(events, description);
    let old = index(command, FORKOP_OPKG_RECOVERY_DIR + "/") >= 0;
    if (index(command, "--noaction") >= 0)
        return true;
    let name = "";
    if (index(command, "luci-i18n-forkop-ru_") >= 0 || index(command, "/i18n.ipk") >= 0) name = "luci-i18n-forkop-ru";
    else if (index(command, "luci-app-forkop_") >= 0 || index(command, "/app.ipk") >= 0) name = "luci-app-forkop";
    else if (index(command, "forkop_") >= 0 || index(command, "/backend.ipk") >= 0) name = "forkop";
    check(name != "", "unknown package step");
    if (old && name == rollback_failure) return false;
    if (old && name == "forkop") service_running = false; // rollback prerm
    if (!old && name == failure) {
        if (name == "forkop") service_running = false;
        return false;
    }
    if (!old && name == uncommitted) return true;
    if (!old && name == "forkop") service_running = false;
    versions[name] = old ? "1.0.0-r1" : "1.1.0-r1";
    return true;
}
'''
suffix = r'''
function reset() {
    versions = { "forkop": "1.0.0-r1", "luci-app-forkop": "1.0.0-r1",
        "luci-i18n-forkop-ru": "1.0.0-r1" };
    events = [];
    downloads = [];
    recovery_dir = false;
    marker = "";
    marker_tmp = "";
    rollback_failure = "";
    uncommitted = "";
    forkop_was_running = true;
    service_running = true;
    service_restart_fail = false;
}
for (let target in [ "", "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ]) {
    reset(); failure = target;
    let error = install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
        "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
    if (target == "") {
        check(error == "" && opkg_forkop_set_versions_match("1.1.0", true), "success path failed");
        check(marker == "", "successful upgrade retained recovery marker");
    } else {
        check(index(error, "previous release restored") >= 0, "failure not reported as restored");
        check(opkg_forkop_set_versions_match("1.0.0", true), "mixed package versions after " + target);
        let restores = 0;
        for (let event in events)
            if (index(event, "Restoring Forkop release package ") == 0) restores++;
        check(restores == (target == "forkop" ? 0 : 3), "rollback did not restore the old set");
        check(marker == "", "restored upgrade retained recovery marker");
    }
}
reset(); uncommitted = "luci-i18n-forkop-ru";
check(index(install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && opkg_forkop_set_versions_match("1.0.0", true),
    "uncommitted final package did not trigger rollback");
reset(); failure = "luci-i18n-forkop-ru"; rollback_failure = "luci-app-forkop";
let error = install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
check(index(error, "archives retained") >= 0 && marker != "" && recovery_dir,
    "failed rollback discarded recovery archive");
rollback_failure = ""; failure = "";
check(recover_forkop_opkg_set() == "" && opkg_forkop_set_versions_match("1.0.0", true) && marker == "",
    "pending recovery did not restore previous package set");
reset(); failure = "";
versions["luci-i18n-forkop-ru"] = "";
check(install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "") == "" &&
    opkg_forkop_set_versions_match("1.1.0", false) && versions["luci-i18n-forkop-ru"] == "",
    "upgrade without optional i18n failed");
reset();
versions["luci-app-forkop"] = "0.9.0-r1";
check(index(install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "inconsistent") >= 0 && length(events) == 0, "mixed initial set was not refused");
reset(); failure = "forkop";
check(index(install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && service_running && marker == "",
    "running service was not restored after backend install failure");
reset(); failure = "forkop"; forkop_was_running = false; service_running = false;
check(index(install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && !service_running && marker == "",
    "stopped service was started by rollback");
reset(); failure = "luci-app-forkop"; rollback_failure = "luci-app-forkop";
check(index(install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "archives retained") >= 0 && marker != "" && !service_running,
    "interrupted recovery fixture not established");
rollback_failure = ""; forkop_was_running = false;
check(recover_forkop_opkg_set() == "" && service_running && marker == "",
    "new invocation lost original running state");
reset(); failure = "forkop"; service_restart_fail = true;
check(index(install_forkop_opkg_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "service") >= 0 && marker != "" && !service_running,
    "service restart failure was reported as complete recovery");
service_restart_fail = false;
check(recover_forkop_opkg_set() == "" && service_running && marker == "",
    "service restart retry lost recovery state");
reset(); marker = "1.0.0\t1.1.0\t1\n"; recovery_dir = true;
check(index(recover_forkop_opkg_set(), "unknown") >= 0 && marker != "",
    "legacy marker silently assumed original service state");
print("Forkop OPKG package-set checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prefix + '\n\n'.join(functions) + suffix)
PY

ucode "$WORK_DIR/probe.uc"
