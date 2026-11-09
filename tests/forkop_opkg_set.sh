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
names = ('forkop_release_version_matches', 'forkop_release_matches',
         'forkop_set_package_names', 'opkg_forkop_set_versions_match',
         'forkop_installed_version_mismatch',
         'pkg_set_extension', 'pkg_forkop_set_command', 'forkop_recovery_files',
         'restore_forkop_opkg_service', 'clear_forkop_recovery_metadata',
         'finish_forkop_opkg_recovery', 'forkop_release_is_newer',
         'recover_forkop_opkg_set', 'forkop_package_set_space_error',
         'install_forkop_package_set')
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
let forkop_stopped_for_release_upgrade = false;
let service_running = true;
let service_restart_fail = false;
let versions = {};
let failure = "";
let uncommitted = "";
let rollback_failure = "";
let checksummed_previous = false;
let apk_mode = false;
let hash_matches = false;
let archive_rename_fails = false;
// Packages whose version query fails once their new version is installed:
// opkg refuses even read-only queries while another invocation holds its lock.
let query_errors = {};
let events = [];
let downloads = [];
let recovery_dir = false;
let marker = "";
let marker_tmp = "";
function as_string(value) { return value == null ? "" : "" + value; }
function file_exists(path) { return path == FORKOP_OPKG_RECOVERY_DIR ? recovery_dir : marker != ""; }
function file_nonempty(path) { return index(downloads, path) >= 0; }
function read_file(path) { return marker; }
function write_file(path, value) { marker_tmp = value; return true; }
let fs = { rename: function(source, target) {
    if (source == FORKOP_OPKG_RECOVERY_DIR + "/pending.new") {
        marker = marker_tmp; marker_tmp = ""; return true;
    }
    let i = index(downloads, source);
    if (i < 0 || archive_rename_fails) return false;
    downloads[i] = target;
    return true;
} };
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
function read_installed_package_version(name) {
    if (query_errors[name] && versions[name] == "1.1.0-r1")
        return { state: "error", version: "", error: "opkg_conf_load: Could not lock /var/lock/opkg.lock: Resource temporarily unavailable." };
    return versions[name] ? { state: "found", version: versions[name], error: "" } :
        { state: "missing", version: "", error: "" };
}
function forkop_status_running_with_timeout() { return service_running; }
function previous_forkop_release(version) {
    check(version == FORKOP_VERSION, "wrong previous release");
    let ext = apk_mode ? "apk" : "ipk";
    let backend = "forkop_1.0.0." + ext;
    let app = "luci-app-forkop_1.0.0." + ext;
    let i18n = "luci-i18n-forkop-ru_1.0.0." + ext;
    let sums = {};
    sums[backend] = "expected"; sums[app] = "expected"; sums[i18n] = "expected";
    return { backend_name: backend, backend_url: "old-backend",
        app_name: app, app_url: "old-app", i18n_name: i18n, i18n_url: "old-i18n",
        checksums: checksummed_previous ? sums : null };
}
function download_with_retry(url, path, label) { push(downloads, path); return true; }
function command_from_args(args) { return join(" ", args); }
function command_output_from_args(args) {
    if (args[0] == "sha256sum") return (hash_matches ? "expected" : "mismatch") + "  " + args[1];
    check(args[0] == "dirname", "unexpected path command");
    return "/";
}
function ensure_dir(path) { return path == "/"; }
function is_apk() { return apk_mode; }
// Free space is exercised by its own test, so leave room here.
function available_kib(path) { return 1048576; }
function file_bytes(path) { return 0; }
function path_basename(path) { let parts = split(path, "/"); return parts[length(parts) - 1]; }
function updates_log(message, level) { push(events, message); }
function capture_managed_upgrade_sing_box_marker() { push(events, "Managed sing-box provenance captured"); }
function stop_old_sing_box_before_forkop_upgrade() {
    service_running = false;
    return true;
}
function run_logged(description, command) {
    push(events, description);
    let old = index(command, FORKOP_OPKG_RECOVERY_DIR + "/") >= 0;
    if (old && apk_mode)
        check(index(command, ".ipk") < 0, "APK rollback/preflight used an IPK path");
    if (index(command, "--noaction") >= 0 || index(command, "--simulate") >= 0)
        return true;
    let count = 0;
    for (let pair in [["luci-app-forkop", "app"], ["luci-i18n-forkop-ru", "i18n"], ["forkop", "backend"]]) {
        let name = pair[0];
        if (index(command, name + "_") < 0 && index(command, "/" + pair[1] + "." + (apk_mode ? "apk" : "ipk")) < 0)
            continue;
        count++;
        if (old && name == rollback_failure) return false;
        if (old && name == "forkop") service_running = false;
        if (!old && name == failure) {
            if (name == "forkop") service_running = false;
            return false;
        }
        if (!old && name == uncommitted) continue;
        if (!old && name == "forkop") service_running = false;
        versions[name] = old ? "1.0.0-r1" : "1.1.0-r1";
    }
    check(count > 0, "unknown package step");
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
    checksummed_previous = false;
    apk_mode = false;
    hash_matches = false;
    archive_rename_fails = false;
    uncommitted = "";
    forkop_was_running = true;
    forkop_stopped_for_release_upgrade = false;
    service_running = true;
    service_restart_fail = false;
    query_errors = {};
}
for (let target in [ "", "forkop", "luci-app-forkop", "luci-i18n-forkop-ru" ]) {
    reset(); failure = target;
    let error = install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
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
reset(); checksummed_previous = true;
let checksum_error = install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
check(index(checksum_error, "checksum mismatch") >= 0, "bad rollback checksum was accepted");
check(opkg_forkop_set_versions_match("1.0.0", true), "bad rollback checksum changed packages");
reset(); uncommitted = "luci-i18n-forkop-ru";
check(index(install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && opkg_forkop_set_versions_match("1.0.0", true),
    "uncommitted final package did not trigger rollback");
reset(); failure = "luci-i18n-forkop-ru"; rollback_failure = "luci-app-forkop";
let error = install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
check(index(error, "archives retained") >= 0 && marker != "" && recovery_dir,
    "failed rollback discarded recovery archive");
rollback_failure = ""; failure = "";
check(recover_forkop_opkg_set() == "" && opkg_forkop_set_versions_match("1.0.0", true) && marker == "",
    "pending recovery did not restore previous package set");
reset(); query_errors = { "luci-app-forkop": true };
let busy_error = install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
check(busy_error == "", "a failed version query rolled back a good upgrade: " + busy_error);
check(versions["luci-app-forkop"] == "1.1.0-r1" && marker == "", "a failed version query left the upgrade unfinished");
let busy_logged = false;
for (let event in events) {
    if (index(event, "Restoring Forkop release package ") == 0) check(false, "a failed version query restored the old set");
    if (index(event, "Could not read the installed version of luci-app-forkop after installation: opkg_conf_load") == 0) busy_logged = true;
}
check(busy_logged, "the failed version query was not logged");
reset(); uncommitted = "luci-i18n-forkop-ru";
install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk");
let named = false;
for (let event in events)
    if (event == "Forkop package versions disagree after installation (expected 1.1.0, installed luci-i18n-forkop-ru 1.0.0-r1)") named = true;
check(named, "a version that disagrees was not named with what was read");
reset(); failure = "";
versions["luci-i18n-forkop-ru"] = "";
check(install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "") == "" &&
    opkg_forkop_set_versions_match("1.1.0", false) && versions["luci-i18n-forkop-ru"] == "",
    "upgrade without optional i18n failed");
reset();
versions["luci-app-forkop"] = "0.9.0-r1";
check(index(install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "inconsistent") >= 0 && length(events) == 0, "mixed initial set was not refused");
reset(); failure = "forkop";
check(index(install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && service_running && marker == "",
    "running service was not restored after backend install failure");
reset(); failure = "forkop"; forkop_was_running = false; service_running = false;
check(index(install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "previous release restored") >= 0 && !service_running && marker == "",
    "stopped service was started by rollback");
reset(); failure = "luci-app-forkop"; rollback_failure = "luci-app-forkop";
check(index(install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "archives retained") >= 0 && marker != "" && !service_running,
    "interrupted recovery fixture not established");
rollback_failure = ""; forkop_was_running = false;
check(recover_forkop_opkg_set() == "" && service_running && marker == "",
    "new invocation lost original running state");
reset(); failure = "forkop"; service_restart_fail = true;
check(index(install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.ipk",
    "/new/luci-app-forkop_1.1.0.ipk", "/new/luci-i18n-forkop-ru_1.1.0.ipk"),
    "service") >= 0 && marker != "" && !service_running,
    "service restart failure was reported as complete recovery");
service_restart_fail = false;
check(recover_forkop_opkg_set() == "" && service_running && marker == "",
    "service restart retry lost recovery state");
reset(); marker = "1.0.0\t1.1.0\t1\n"; recovery_dir = true;
check(index(recover_forkop_opkg_set(), "unknown") >= 0 && marker != "",
    "legacy marker silently assumed original service state");
// The APK updater must stage the same names its recovery reads, including
// partial multi-package installs and optional translation packages.
for (let translated in [false, true]) {
    for (let failed in [false, true]) {
        reset(); apk_mode = true;
        failure = failed ? "forkop" : "";
        let error = install_forkop_package_set("1.1.0", "/new/forkop_1.1.0.apk",
            "/new/luci-app-forkop_1.1.0.apk", translated ? "/new/luci-i18n-forkop-ru_1.1.0.apk" : "");
        check(error == (failed ? "Forkop package-set upgrade failed; previous release restored" : ""), "APK install/rollback failed: " + error);
        check(opkg_forkop_set_versions_match(failed ? "1.0.0" : "1.1.0", translated) && marker == "", "APK set left inconsistent");
    }
}

// Reproduce a healthy newer installation with an obsolete older marker. It
// must neither downgrade packages nor replay the old stopped service state.
reset(); marker = "0.8.0\t0.9.0\t1\t0\n"; recovery_dir = true;
check(recover_forkop_opkg_set() == "" && marker == "" && service_running &&
    opkg_forkop_set_versions_match("1.0.0", true), "obsolete marker damaged the newer installation");
for (let event in events)
    check(index(event, "Restoring Forkop release package ") < 0, "obsolete marker triggered a downgrade");
reset(); marker = "0.8.0\t0.9.0\t1\t1\n"; recovery_dir = true; service_running = false;
check(index(recover_forkop_opkg_set(), "manual recovery") >= 0 && marker != "" &&
    !service_running && opkg_forkop_set_versions_match("1.0.0", true), "inactive newer installation was downgraded or started");
reset(); marker = "0.8.0\t0.9.0\t1\t1\n"; recovery_dir = true;
versions["luci-app-forkop"] = "0.9.0-r1";
check(index(recover_forkop_opkg_set(), "manual recovery") >= 0 && marker != "", "mixed packages cleared the recovery marker");
reset(); marker = "0.8.0\t0.9.0\t0\t1\n"; recovery_dir = true;
versions["luci-i18n-forkop-ru"] = "0.9.0-r1";
check(index(recover_forkop_opkg_set(), "manual recovery") >= 0 && marker != "", "installed optional translation was not checked");
check(forkop_release_is_newer("1.0.78", "1.0.9") && !forkop_release_is_newer("1.0.9", "1.0.78") &&
    !forkop_release_is_newer("invalid", "1.0.9"), "release ordering is not numeric and conservative");

// Valid old APK content under .ipk names can be recovered, but only after
// checking the published APK hashes. Missing, bad, unverifiable and
// unrenameable archives must preserve recovery state and change no packages.
for (let problem in ["", "bad-hash", "no-hash", "rename", "missing"]) {
    reset(); apk_mode = true; checksummed_previous = problem != "no-hash";
    hash_matches = problem != "bad-hash"; archive_rename_fails = problem == "rename";
    marker = "1.0.0\t1.1.0\t1\t1\n"; recovery_dir = true;
    versions["luci-app-forkop"] = "1.1.0-r1";
    downloads = ["/recovery/backend.ipk", "/recovery/app.ipk", "/recovery/i18n.ipk"];
    if (problem == "missing") downloads = [];
    let result = recover_forkop_opkg_set();
    if (problem == "")
        check(result == "" && marker == "" && service_running && opkg_forkop_set_versions_match("1.0.0", true), "legacy APK recovery failed");
    else
        check(result != "" && marker != "" && versions["luci-app-forkop"] == "1.1.0-r1", "unverified legacy APK changed packages");
}
print("Forkop OPKG/APK package-set checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prefix + '\n\n'.join(functions) + suffix)
PY

ucode "$WORK_DIR/probe.uc"
