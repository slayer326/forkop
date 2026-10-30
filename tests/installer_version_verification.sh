#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="$ROOT/forkop/files/usr/lib/components/action.uc"
# Ported from Screamshow/forkop-x 4fd47951. What a read version means for the
# package set after an upgrade is covered by tests/forkop_opkg_set.sh.

# A failed version query must not be read as a wrong version.
{
cat <<'UCODE'
let calls = 0;
let waits = 0;
let script = [];
let status_code = 0;
const LIB_DIR = "/usr/lib/forkop";
function as_string(value) { return value == null ? "" : "" + value; }
function shell_quote(value) { return value; }
function module_command(args) { return "ucode " + args[1]; }
function make_tmp_file(prefix) { return "mock-output"; }
function owner_pid() { return 1; }
function updates_log(message, level) {}
function remove_file(path) {}
function command_status(command) { calls++; return status_code; }
function read_file(path) { return script[calls - 1] != null ? script[calls - 1] : script[length(script) - 1]; }
function command_success_from_args(args) {
    assert(args[0] == "sleep" && args[1] == "1", "unexpected command");
    waits++;
    return true;
}
UCODE
sed -n '/^function read_installed_package_version(package_name) {/,/^}/p' "$ACTION"
cat <<'UCODE'
script = [ "found 2.5.0\n" ];
let state = read_installed_package_version("forkop");
assert(state.state == "found" && state.version == "2.5.0", "installed version not read");
assert(calls == 1 && waits == 0, "successful query retried");

calls = 0; waits = 0;
script = [ "missing\n" ];
state = read_installed_package_version("forkop");
assert(state.state == "missing" && state.version == "", "missing package not reported");
assert(calls == 1 && waits == 0, "missing package retried");

calls = 0; waits = 0;
script = [
    "error opkg_conf_load: Could not lock /var/lock/opkg.lock\n",
    "error opkg_conf_load: Could not lock /var/lock/opkg.lock\n",
    "found 2.5.0\n"
];
state = read_installed_package_version("forkop");
assert(state.state == "found" && state.version == "2.5.0", "transient query failure not retried");
assert(calls == 3 && waits == 2, "incorrect retry state");

calls = 0; waits = 0;
script = [ "error opkg_conf_load: Could not lock /var/lock/opkg.lock\n" ];
state = read_installed_package_version("forkop");
assert(state.state == "error", "persistent query failure accepted as a version");
assert(index(state.error, "Could not lock") >= 0, "package manager error lost");
assert(calls == 3 && waits == 2, "retry bound incorrect");

calls = 0; waits = 0; status_code = 7;
script = [ "" ];
state = read_installed_package_version("forkop");
assert(state.state == "error" && index(state.error, "exit code 7") >= 0, "silent failure not reported");
print("installed version read tests passed\n");
UCODE
} | ucode -

