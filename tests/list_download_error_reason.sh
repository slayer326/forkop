#!/bin/sh
set -eu

# A failed list download names curl's reason in the attempt log line.
#
# Ping can reach a host while HTTPS to it fails: no CA bundle, a refused
# service proxy, a TLS reset. Without curl's own error every attempt only said
# "failed", so the cause could not be told from the log.
#
# The real download functions run with a stubbed command runner; nothing is
# downloaded.

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATES="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() {
  printf 'list_download_error_reason: FAIL: %s\n' "$1" >&2
  exit 1
}

{
  cat <<'UCODE'
function as_string(value) { return value == null ? "" : "" + value; }
const fs = { unlink: function() {} };
let curl_result = { status: 0, output: "" };
let commands = [];
let messages = [];
function parent_dir(path) { return "/tmp"; }
function command_output_from_args(args) {
    return "Filesystem 1024-blocks Used Available Capacity Mounted\ntmpfs 100000 0 100000 0% /tmp\n";
}
function command_from_args(args) { return join(" ", args); }
function list_curl_args(url, filepath, proxy_address, resolve) { return [ "curl", url ]; }
function command_capture(command) { push(commands, command); return curl_result; }
function log_message(message, level) { push(messages, message); }
const LIST_DOWNLOAD_MIN_FREE_BYTES = 1024;
UCODE
  source_between "$UPDATES" '^function safe_remote_source_identity\(' '^function [a-z_]*\(' ||
    fail "safe_remote_source_identity was not found"
  source_between "$UPDATES" '^// The reason of the last failed curl run' '^function download_to_file_with_bootstrap\(' ||
    fail "the download error functions were not found"
} >"$WORK_DIR/harness.uc"
cat >>"$WORK_DIR/harness.uc" <<'UCODE'
function check(condition, message) { if (!condition) die(message + "\n"); }
const URL = "https://cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main/Subnets/IPv4/discord.lst";

curl_result = { status: 60, output: "curl: (60) SSL certificate problem: unable to get local issuer certificate\n" };
check(download_to_file_once(URL, "/tmp/x", "", null) == 60, "curl's status was lost");
check(index(commands[0], " 2>&1") > 0, "curl's stderr was not captured");
let line = download_attempt_failed_message(1, URL);
check(line == "Attempt 1/3 to download cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main/Subnets/IPv4/discord.lst failed: " +
    "curl: (60) SSL certificate problem: unable to get local issuer certificate", "wrong attempt line: " + line);
check(download_attempt_failed_message(2, URL) == "Attempt 2/3 to download " +
    "cdn.jsdelivr.net/gh/itdoginfo/allow-domains@main/Subnets/IPv4/discord.lst failed", "a reason was repeated");

curl_result = { status: 7, output: "curl: (7) Failed to connect to 127.0.0.1 port 4534 after 0 ms: Connection refused\n" };
download_to_file_once(URL, "/tmp/x", "127.0.0.1:4534", null);
line = download_attempt_failed_message(1, URL);
check(index(line, "Connection refused (through the Forkop service proxy 127.0.0.1:4534)") > 0, "the proxy was not named: " + line);

curl_result = { status: 127, output: "" };
download_to_file_once(URL, "/tmp/x", "", null);
check(index(download_attempt_failed_message(1, URL), "failed: curl is not installed") > 0, "a missing curl was not named");

curl_result = { status: 28, output: "" };
download_to_file_once(URL, "/tmp/x", "", null);
check(index(download_attempt_failed_message(1, URL), "failed: curl exit code 28") > 0, "a silent exit code was lost");

curl_result = { status: 6, output: "curl: (6) Could not resolve host\n" };
download_to_file_once(URL, "/tmp/x", "", null);
curl_result = { status: 0, output: "" };
check(download_to_file_once(URL, "/tmp/x", "", null) == 0, "a successful retry failed");
check(last_download_error == "", "a successful retry kept the earlier reason");
print("ok\n");
UCODE

out="$(ucode "$WORK_DIR/harness.uc" 2>&1)" || fail "$out"
[ "$out" = "ok" ] || fail "$out"

printf 'list_download_error_reason: PASS\n'
