#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

source = (pathlib.Path(sys.argv[1]) / 'forkop/files/usr/lib/service/lifecycle.uc').read_text()
names = ('snapshot_dnsmasq_reload_config', 'restore_dnsmasq_reload_config',
         'discard_dnsmasq_reload_config')
functions = []
for name in names:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    functions.append(match.group())

prefix = r'''
let fs = require("fs");
const DNSMASQ_CONFIG_FILE = ARGV[0];
let dns_reload_backup = "";
let backup_path = ARGV[1];
let restart_ok = true;
let restart_calls = 0;
function check(ok, message) { if (!ok) { warn("FAIL: " + message + "\n"); exit(1); } }
function command_output_from_args(args) {
    check(args[0] == "mktemp", "unexpected temporary-file command");
    fs.writefile(backup_path, "");
    return backup_path;
}
function command_success_from_args(args) {
    if (args[0] == "cp")
        return system("cp '" + args[1] + "' '" + args[2] + "'") == 0;
    if (args[1] == "restart") { restart_calls++; return restart_ok; }
    check(false, "unexpected command");
}
function remove_file(path) { fs.unlink(path); }
'''
suffix = r'''
fs.writefile(DNSMASQ_CONFIG_FILE, "old dns\n");
check(snapshot_dnsmasq_reload_config(), "snapshot failed");
fs.writefile(DNSMASQ_CONFIG_FILE, "new dns\n");
check(restore_dnsmasq_reload_config(), "restore failed");
check(fs.readfile(DNSMASQ_CONFIG_FILE) == "old dns\n" && dns_reload_backup == "" &&
    fs.stat(backup_path) == null && restart_calls == 1, "previous DNS state was not restored");

check(snapshot_dnsmasq_reload_config(), "second snapshot failed");
fs.writefile(DNSMASQ_CONFIG_FILE, "changed dns\n");
restart_ok = false;
check(!restore_dnsmasq_reload_config() && dns_reload_backup == backup_path &&
    fs.stat(backup_path) != null, "failed restart discarded rollback copy");
restart_ok = true;
check(restore_dnsmasq_reload_config() && fs.readfile(DNSMASQ_CONFIG_FILE) == "old dns\n",
    "retry did not restore DNS");

check(snapshot_dnsmasq_reload_config(), "third snapshot failed");
discard_dnsmasq_reload_config();
check(fs.stat(backup_path) == null && dns_reload_backup == "", "commit retained DNS backup");
print("dnsmasq reload snapshot checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prefix + '\n\n'.join(functions) + suffix)
PY

ucode "$WORK_DIR/probe.uc" "$WORK_DIR/dhcp" "$WORK_DIR/dhcp.backup"
