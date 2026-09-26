#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIFECYCLE="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT HUP INT TERM

cat > "$STATE_DIR/fault.uc" <<'UCODE'
let fs = require("fs");
const ZAPRET_UC = "zapret";
const ZAPRET2_UC = "zapret2";
const BYEDPI_UC = "byedpi";
const NFT_UC = "nft";
const NFT_TABLE_NAME = "ForkopTable";
const NFT_FAKEIP_MARK = "0x04000000";
const RELOAD_STATE_SNAPSHOT_FILE = "reload-state.snapshot";
let dpi_snapshot_dir = "";
let dpi_switch_started = false;
let dpi_restart_plan = null;
let dpi_nft_rollback_file = "";
let dpi_nft_committed = false;
let dpi_singbox_backup = "";
let dpi_guard_active = false;
let restored = 0;
let owned_stops = 0;
let stopped = 0;
let started = 0;
let cleaned = 0;
let removed_state = 0;
let nft_restores = 0;
let fault = ARGV[0];
let dns_restore_ok = fault != "dns-rollback-fail";
function command_output_from_args(args) { return ARGV[1]; }
function command_from_args(args) { return join(" ", args); }
function command_success_from_args(args) { return true; }
function system(command) { nft_restores++; return 0; }
function log_message(message, level) {}
function module_success(path, args) { return true; }
function cleanup_failed_runtime() { cleaned++; }
function restore_dnsmasq_reload_config() { return dns_restore_ok; }
function remove_file(path) { removed_state++; }
function module_status(path, args) {
    if (args[0] == "snapshot-runtime") {
        fs.writefile(args[1], "[]\n");
        return 0;
    }
    if (args[0] == "restore-runtime") {
        restored++;
        return fault == "rollback-restore-fail" && path == ZAPRET2_UC ? 1 : 0;
    }
    if (args[0] == "preflight-runtime")
        return fault == "rollback-preflight-fail" && path == ZAPRET2_UC ? 1 : 0;
    if (args[0] == "stop-owned-runtime") {
        owned_stops++;
        return fault == "rollback-stop-fail" && path == ZAPRET_UC ? 1 : 0;
    }
    if (args[0] == "stop-runtime") {
        stopped++;
        return fault == "after-stop" && path == ZAPRET_UC ? 1 : 0;
    }
    if (args[0] == "start-runtime") {
        started++;
        return fault == path ? 1 : 0;
    }
    return 1;
}
UCODE

# Exercise the real production rollback functions with faulting provider calls.
awk '/^function discard_dpi_snapshot\(\)/ { copy=1 } /^function start_inner\(\)/ { copy=0 } copy { print }' "$LIFECYCLE" >> "$STATE_DIR/fault.uc"

cat >> "$STATE_DIR/fault.uc" <<'UCODE'
let plan = { needs_zapret_restart: 1, needs_zapret2_restart: 1, needs_byedpi_restart: 1 };
if (!snapshot_dpi_runtime(plan))
    exit(10);
if (fault == "dns" || fault == "dns-rollback-fail") {
    if (switch_dpi_runtime(plan) != 0 || abort_reload_after_dns_failure(1) == 0)
        exit(18);
    if (fault == "dns" && (restored != 3 || cleaned != 0))
        exit(19);
    if (fault == "dns-rollback-fail" && (restored != 0 || cleaned != 0 || !dpi_guard_active || dpi_snapshot_dir == ""))
        exit(20);
    exit(0);
}
if (fault == "postcommit") {
    dpi_switch_started = true;
    dpi_guard_active = false;
    dpi_nft_committed = true;
    dpi_nft_rollback_file = ARGV[1] + "/nft.rollback";
    if (abort_reload(1, true) == 0 || restored != 3 || nft_restores != 1 || cleaned != 0)
        exit(17);
    exit(0);
}
let status = switch_dpi_runtime(plan);
if ((fault == "rollback-stop-fail" || fault == "rollback-preflight-fail" || fault == "rollback-restore-fail") && status == 0) {
    if (abort_reload(1, false) == 0 || !dpi_guard_active || dpi_snapshot_dir == "")
        exit(21);
    if (fault == "rollback-preflight-fail" && (restored != 0 || owned_stops != 0))
        exit(22);
    if (fault == "rollback-stop-fail" && (restored != 0 || owned_stops != 1))
        exit(23);
    if (fault == "rollback-restore-fail" && (restored != 2 || owned_stops != 4))
        exit(24);
    exit(0);
}
if (status == 0 || abort_reload(status, false) == 0)
    exit(11);
if (restored != 3 || cleaned != 0 || removed_state != 1)
    exit(12);
if (fault == "after-stop" && (stopped != 1 || started != 0))
    exit(13);
if (fault == ZAPRET_UC && started != 1)
    exit(14);
if (fault == ZAPRET2_UC && started != 2)
    exit(15);
if (fault == BYEDPI_UC && started != 3)
    exit(16);
UCODE

for fault in after-stop zapret zapret2 byedpi postcommit dns dns-rollback-fail rollback-preflight-fail rollback-stop-fail rollback-restore-fail; do
    ucode "$STATE_DIR/fault.uc" "$fault" "$STATE_DIR" || {
        printf 'dpi_reload_faults: FAIL (%s)\n' "$fault" >&2
        exit 1
    }
done

last_switch="$(grep -nF 'status = switch_dpi_runtime(plan);' "$LIFECYCLE" | tail -n 1 | cut -d: -f1)"
state_commit="$(grep -nF 'status = finish_reload_status(module_status(STATE_UC, [' "$LIFECYCLE" | tail -n 1 | cut -d: -f1)"
[ -n "$last_switch" ] && [ -n "$state_commit" ] && [ "$last_switch" -lt "$state_commit" ] || {
    printf 'dpi_reload_faults: state committed before DPI readiness\n' >&2
    exit 1
}

printf 'dpi_reload_faults: PASS\n'
