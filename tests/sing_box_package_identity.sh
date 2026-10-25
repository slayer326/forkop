#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Run the actual diagnostics functions with deterministic package-manager and
# marker doubles. No installed package or live daemon is touched by this test.
python3 - "$ROOT_DIR" "$WORK_DIR/probe.uc" <<'PY'
import pathlib
import re
import sys

source = (pathlib.Path(sys.argv[1]) / 'forkop/files/usr/lib/diagnostics/runtime.uc').read_text()
functions = []
for name in ['sing_box_package_from_manifest', 'sing_box_installed_package_name',
             'sing_box_live_probe_disabled', 'sing_box_capability_flags']:
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if not match:
        raise SystemExit('missing diagnostics function: ' + name)
    functions.append(match.group())

prelude = r'''
const SINGBOX_RUNTIME_UC = "singbox/runtime.uc";
let marker = "";
let action_running = false;
let apk_manifest = "";
let opkg_manifest = "";
function as_string(value) { return value == null ? "" : "" + value; }
function sing_box_marker_is(value) { return marker == value; }
function sing_box_component_action_running() { return action_running; }
function module_success(path, args) {
    if (path == SINGBOX_RUNTIME_UC && args[0] == "is-extended")
        return index(as_string(args[1]), "extended") >= 0;
    die("unexpected diagnostics helper");
}
function command_output_from_args(args) {
    if (join(" ", args) == "apk list --installed --manifest") return apk_manifest;
    if (join(" ", args) == "opkg list-installed") return opkg_manifest;
    die("unexpected package-manager command");
}
function check(condition, message) { if (!condition) die(message); }
'''
cases = r'''
apk_manifest = "sing-box-tiny 1.13.14-r1\nsing-box-tools 1.0-r1\n";
check(sing_box_installed_package_name() == "sing-box-tiny", "virtual provides confused Tiny identity");
apk_manifest = "sing-box-helper 1.0-r1\n";
opkg_manifest = "sing-box - 1.13.14-r1\n";
check(sing_box_installed_package_name() == "sing-box", "OPKG exact package fallback failed");
opkg_manifest = "sing-box-extended - 1.14-r1\n";
check(sing_box_installed_package_name() == "sing-box-extended", "OPKG extended identity failed");
opkg_manifest = "";
check(sing_box_installed_package_name() == "", "package prefix accepted as exact identity");

for (let package_name in [ "sing-box", "sing-box-tiny", "sing-box-extended", "" ]) {
    action_running = true;
    check(sing_box_live_probe_disabled(package_name), "component replacement allowed a live probe");
}
action_running = false;
for (let old_marker in [ "tiny", "extended", "extended-compressed" ]) {
    marker = old_marker;
    check(!sing_box_live_probe_disabled("sing-box"), "stale marker suppressed regular-package discovery");
    let regular = sing_box_capability_flags("1.13.14", "Tags: with_quic\n", "sing-box");
    check(regular.extended == 0 && regular.tiny == 0 && regular.tailscale == 0,
        "stale marker overrode regular-package capabilities");
    let tiny = sing_box_capability_flags("1.13.14", "Tags: with_quic,with_tailscale\n", "sing-box-tiny");
    check(tiny.extended == 0 && tiny.tiny == 1 && tiny.tailscale == 0,
        "stale marker or output overrode Tiny identity");
    let extended = sing_box_capability_flags("1.14-extended", "", "sing-box-extended");
    check(extended.extended == 1 && extended.tiny == 0 && extended.tailscale == 1,
        "exact Extended package was not recognized");
}
marker = "extended-compressed";
check(sing_box_live_probe_disabled(""), "unmanaged compressed variant was probed");
let compressed = sing_box_capability_flags("1.14-extended", "", "");
check(compressed.extended == 1 && compressed.tiny == 0 && compressed.tailscale == 1,
    "unmanaged compressed variant fallback was lost");
marker = "";
let unknown = sing_box_capability_flags("1.13.14", "Tags: with_quic\n", "");
check(unknown.extended == 0 && unknown.tiny == 0 && unknown.tailscale == 0,
    "absence of Tailscale was incorrectly interpreted as Tiny");
let measured = sing_box_capability_flags("1.13.14", "Tags: with_quic,with_tailscale\n", "sing-box");
check(measured.tailscale == 1, "measured Tailscale tag was lost");

// podkop-engine provides sing-box under its own package names.
apk_manifest = "podkop-engine-full 1.14.3-r16\nsing-box-tools 1.0-r1\n";
check(sing_box_installed_package_name() == "podkop-engine-full", "podkop-engine-full identity failed");
apk_manifest = "podkop-engine 1.14.3-r16\n";
check(sing_box_installed_package_name() == "podkop-engine", "podkop-engine identity failed");
marker = "tiny";
let pdk = sing_box_capability_flags("1.14.3-pdk-r16", "Tags: with_quic\nFeatures: transport.xhttp\n", "podkop-engine");
check(pdk.podkop_engine == 1 && pdk.podkop_engine_full == 0 && pdk.extended == 0 && pdk.tiny == 0 && pdk.tailscale == 0,
    "podkop-engine flags were wrong or a stale tiny marker overrode them");
let pdk_full = sing_box_capability_flags("1.14.3-pdk-r16", "", "podkop-engine-full");
check(pdk_full.podkop_engine == 1 && pdk_full.podkop_engine_full == 1, "podkop-engine-full flags were wrong");
marker = "";
let pdk_unowned = sing_box_capability_flags("1.14.3-pdk-r16", "", "");
check(pdk_unowned.podkop_engine == 1 && pdk_unowned.podkop_engine_full == 0, "podkop-engine version alone was not recognized");
let regular_pdk = sing_box_capability_flags("1.14.3", "", "sing-box");
check(regular_pdk.podkop_engine == 0, "regular sing-box was taken for podkop-engine");
print("sing-box package identity checks passed\n");
'''
pathlib.Path(sys.argv[2]).write_text(prelude + '\n\n'.join(functions) + cases)
PY

ucode "$WORK_DIR/probe.uc"
