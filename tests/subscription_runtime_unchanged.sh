#!/usr/bin/env bash
set -euo pipefail

# A subscription refresh whose generated sing-box configuration is unchanged
# publishes the new section cache and skips the reload, so clients keep their
# connections. Any semantic difference, a stopped runtime or a failed
# comparison keeps the reload.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_UC="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

{
cat <<'UC'
let current, candidate, running, prepare_ok, publish_ok, calls;
function trim(v) { return replace(v, /^[ \t\r\n]+|[ \t\r\n]+$/g, ""); }
function service_state_success(args) {
    push(calls, join(" ", args));
    if (args[0] == "sing-box-current-owned-service-runtime")
        return running;
    die("unexpected service mutation\n");
}
function command_output_from_args(args) { return "probe"; }
function command_success_from_args(args) { push(calls, join(" ", args)); return true; }
let fs = { chmod: function(p, m) { return true; } };
function read_json_file(path) { return path == "config" ? current : candidate; }
function singbox_runtime_success(args) {
    push(calls, join(" ", args));
    if (args[0] == "prepare-config-stage") return prepare_ok;
    if (args[0] == "publish-section-cache") return publish_ok;
    if (args[0] == "discard-config-stage") return true;
    die("unexpected runtime mutation\n");
}
UC
sed -n '/^function subscription_config_value(/,/^}/p' "$UPDATES_UC"
sed -n '/^function subscription_runtime_change_check(/,/^}/p' "$UPDATES_UC"
cat <<'UC'
let fixture = {
    outbounds: [
        { type: "vless", tag: "p", server: "node.invalid", server_port: 443 },
        { type: "selector", tag: "section", outbounds: [ "p", "direct" ] }
    ],
    route: { final: "section" },
    dns: { servers: [ { tag: "dns", server: "1.1.1.1" } ] }
};
function reset() {
    current = json(sprintf("%J", fixture));
    candidate = json(sprintf("%J", fixture));
    running = true; prepare_ok = true; publish_ok = true; calls = [];
}
function expect(label, changed, ok) {
    let result = subscription_runtime_change_check("config");
    if (result.changed != changed || result.ok != ok)
        die(label + ": got changed=" + result.changed + " ok=" + result.ok + "\n");
}

// Key order may differ; array order stays meaningful.
reset();
candidate = { dns: fixture.dns, route: fixture.route, outbounds: fixture.outbounds };
expect("same config, other key order", false, true);
let text = join("\n", calls);
if (index(text, "publish-section-cache") < 0 || index(text, "discard-config-stage") < 0)
    die("unchanged config did not publish the section cache and discard the stage\n");

reset(); candidate.outbounds[0].server = "other.invalid"; expect("server", true, true);
reset(); candidate.outbounds[1].outbounds = [ "direct", "p" ]; expect("selector order", true, true);
reset(); candidate.route.final = "direct"; expect("route", true, true);
reset(); candidate.dns.servers[0].server = "9.9.9.9"; expect("dns", true, true);
reset(); candidate = null; expect("missing candidate", true, false);
reset(); prepare_ok = false; expect("failed preparation", true, false);
reset(); publish_ok = false; expect("failed cache publication", false, false);
reset(); running = false; expect("stopped runtime", true, true);
if (length(calls) != 1)
    die("a stopped runtime was staged\n");
print("ok\n");
UC
} > "$WORK_DIR/check.uc"

ucode "$WORK_DIR/check.uc" >/dev/null || fail "change check behaviour"

common_body="$(sed -n '/^function subscription_update_common_locked(/,/^}/p' "$UPDATES_UC")"
check_line="$(grep -nF 'subscription_runtime_change_check(sing_box_config_path)' <<<"$common_body" | cut -d: -f1)"
reload_line="$(grep -nF 'Reloading sing-box to apply updated subscriptions' <<<"$common_body" | cut -d: -f1)"
[ -n "$check_line" ] && [ -n "$reload_line" ] && [ "$check_line" -lt "$reload_line" ] ||
  fail "the update does not compare the configuration before reloading"
grep -Fq 'else if (!change.changed) {' <<<"$common_body" ||
  fail "a failed comparison must fall back to the reload, not skip it"
grep -Fq 'mode == "publish-section-cache"' "$ROOT_DIR/forkop/files/usr/lib/singbox/runtime.uc" ||
  fail "sing-box runtime does not expose publish-section-cache"

printf 'Subscription unchanged-runtime checks passed\n'
