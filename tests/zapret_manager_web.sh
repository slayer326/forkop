#!/bin/sh
set -eu
# Installing Zapret Manager from Forkop runs the Forkop X 2.6 migration
# script: it installs the Forkop flavour of the panel and the mirror
# launchers, and restores every file it touched when a step fails. Removal
# takes the web version along. Zapret-Manager's automatic strategy selection
# stays off: Forkop removes the auto-best cron jobs on install and on every
# cron refresh.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="$ROOT/forkop/files/usr/lib/components/action.uc"
UPDATES="$ROOT/forkop/files/usr/lib/components/updates.uc"
fail() { printf 'zapret_manager_web: FAIL: %s\n' "$*" >&2; exit 1; }

ucode -e '
let fs = require("fs");
let source = fs.readfile(ARGV[0]);
function extract(name) {
    let start = index(source, "function " + name + "(");
    assert(start >= 0, name + " exists");
    let tail = substr(source, start);
    return substr(tail, 0, index(tail, "\n}") + 2);
}
function constant(name) {
    let start = index(source, "const " + name + " =");
    assert(start >= 0, name + " exists");
    let tail = substr(source, start);
    return substr(tail, 0, index(tail, ";\n") + 2);
}
let code = `
const FORKOP_MIRROR_BASE_URL = "https://mirror.test";
const ZAPRET_MANAGER_WEB_SCRIPT = "/opt/zapret-manager-luci/backend.sh";
const ZAPRET_MANAGER_MIGRATE_SCRIPT = "/usr/share/forkop/zapret-manager-migrate.sh";
const ZAPRET_MANAGER_CRONTAB = "/etc/crontabs/root";
` + constant("ZAPRET_MANAGER_AUTOBEST_MARKERS") + `
let tmp_dir = "/t", files = {}, runs = [], crontabs = [], logs = [], result = null, script_ok = true, script_output = "";
let last_logged_output = "";
function as_string(v) { return v == null ? "" : "" + v; }
function read_file(p) { return files[p] || ""; }
function write_file(p, v) { files[p] = v; return true; }
function remove_file(p) { delete files[p]; }
function make_tmp_file(prefix) { return "/t/" + prefix; }
function updates_log(m, level) { push(logs, m); }
function clear_version_caches() {}
function command_from_args(a) { return join(" ", a); }
function command_success_from_args(a) {
    if (a[0] == "crontab") { push(crontabs, files[a[1]]); files["/etc/crontabs/root"] = files[a[1]]; }
    return true;
}
function run_logged(d, command) {
    push(runs, command);
    last_logged_output = script_output;
    if (script_ok)
        files[ZAPRET_MANAGER_WEB_SCRIPT] = "ZM_VERSION=\\"4.71.2\\"\n";
    return script_ok;
}
function action_fail(component, action, message, current, latest) {
    result = { success: false, action, message, current, latest };
    die("action failed");
}
function action_success(component, action, message, current, latest, changed) {
    result = { success: true, action, message, current, latest, changed };
}
` + join("\n", map([ "zapret_manager_web_installed_version", "crontab_without_zapret_manager_autobest",
    "disable_zapret_manager_autobest", "zapret_manager_launcher_owned",
    "install_zapret_manager" ], extract)) + `
function reset() { files = {}; runs = []; crontabs = []; logs = []; result = null; script_ok = true; script_output = ""; }

reset();
script_output = "Forkop Zapret Manager verified\nFORKOP_ZM_CHANGED=1\n";
install_zapret_manager("install");
assert(runs[0] == "sh /usr/share/forkop/zapret-manager-migrate.sh install https://mirror.test", "install command: " + runs[0]);
assert(result.success && result.changed == 1 && result.current == "" && result.latest == "4.71.2", "install result: " + result);

reset();
files[ZAPRET_MANAGER_WEB_SCRIPT] = "ZM_VERSION=\\"4.71.2\\"\n";
script_output = "FORKOP_ZM_CHANGED=0\n";
install_zapret_manager("migrate");
assert(runs[0] == "sh /usr/share/forkop/zapret-manager-migrate.sh migrate https://mirror.test", "migrate command: " + runs[0]);
assert(result.success && result.changed == 0 && result.current == "4.71.2", "an unchanged panel was reported as changed");

reset();
files[ZAPRET_MANAGER_WEB_SCRIPT] = "ZM_VERSION=\\"4.71\\"\n";
script_ok = false;
try { install_zapret_manager("install"); } catch (e) {}
assert(result != null && !result.success && index(result.message, "restored") > 0 && result.current == "4.71", "failure: " + result);

reset();
files["/etc/crontabs/root"] = "0 4 * * * /usr/bin/zmsA --auto-best >/dev/null 2>&1\n";
install_zapret_manager("install");
assert(result.success && files["/etc/crontabs/root"] == "", "install keeps the auto-best job: " + files["/etc/crontabs/root"]);

assert(zapret_manager_launcher_owned("u=\x27https://mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh\x27"), "migration launcher");
assert(zapret_manager_launcher_owned("exec sh <(wget -q -O - https://mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh)"), "previous mirror launcher");
assert(zapret_manager_launcher_owned("sh <(wget -q -O - https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh) \\"$@\\""), "launcher the script writes");
assert(!zapret_manager_launcher_owned("#!/bin/sh\nmy own zms\n"), "user launcher would be removed");

reset();
files["/etc/crontabs/root"] = "0 1 * * * /bin/true # keep\n0 4 * * * /usr/bin/zmsA --auto-best >/dev/null 2>&1\n30 5 * * * /opt/zapret-manager-luci/backend.sh test_action auto_tick x >/dev/null 2>&1 # zm-autobest\n*/5 * * * * /opt/zapret-manager-luci/backend.sh zm_watch >/dev/null 2>&1 # zm-rpcd-watch\n";
assert(disable_zapret_manager_autobest(), "auto-best not disabled");
assert(files["/etc/crontabs/root"] == "0 1 * * * /bin/true # keep\n*/5 * * * * /opt/zapret-manager-luci/backend.sh zm_watch >/dev/null 2>&1 # zm-rpcd-watch\n", "crontab: " + files["/etc/crontabs/root"]);
assert(length(logs) == 1, "the removal is not logged");
crontabs = [];
assert(disable_zapret_manager_autobest() && length(crontabs) == 0, "a crontab without auto-best was rewritten");
print("ok\n");
`;
let path = "/tmp/forkop-zapret-manager-web." + time() + ".uc";
fs.writefile(path, code);
let status = system([ "ucode", path ]);
fs.unlink(path);
exit(status);
' "$ACTION" >/dev/null || fail 'Zapret-Manager web version and auto-best'

# A package upgrade migrates the panel through the same action, and the
# packages ship both scripts.
grep -Fq 'component == "zapret_manager" && (action == "install" || action == "migrate")' "$ACTION" ||
  fail 'the migrate action is not dispatched'
grep -Fq 'component-action zapret_manager migrate' "$ROOT/forkop/files/usr/share/forkop/zapret-manager-upgrade.sh" ||
  fail 'the upgrade worker does not run the migrate action'
[ "$(grep -c 'queue_zapret_manager_migration();' "$ROOT/forkop/files/usr/lib/service/package.uc")" = 2 ] ||
  fail 'postinst must queue the migration on both of its successful paths'
for script in zapret-manager-migrate.sh zapret-manager-upgrade.sh; do
  grep -Fq "./files/usr/share/forkop/$script" "$ROOT/forkop/Makefile" || fail "Makefile does not ship $script"
  grep -Fq "forkop/files/usr/share/forkop/$script" "$ROOT/build.sh" || fail "build.sh does not ship $script"
done

# Removal refuses a foreign launcher before it removes anything.
awk '
  /^function remove_zapret_manager\(/ { f = 1 }
  f && /zapret_manager_launcher_owned/ && !own { own = NR }
  f && /remove_zapret_manager_web\(\)/ && !web { web = NR }
  f && /remove_file\(path\)/ && !rm { rm = NR }
  f && /^}/ { exit }
  END { exit !(own && web > own && rm > web) }
' "$ACTION" || fail 'removal order: ownership check, web version, launchers'
awk '
  /^function remove_zapret_manager_web\(/ { f = 1 }
  f && /uci_core.delete\("uhttpd.zmweb"\)/ && !del { del = NR }
  f && /uci_core.commit\("uhttpd"\)/ && !commit { commit = NR }
  f && /uhttpd restart/ && !restart { restart = NR }
  f && /^}/ { exit }
  END { exit !(del && commit >= del && restart > commit) }
' "$ACTION" || fail 'the web version removal does not drop its uhttpd instance before the restart'

# Every cron refresh (each Forkop start and reload) removes the auto-best
# jobs again, should they have been turned on in Zapret-Manager.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' '{ "settings": { "list_update_enabled": "0" }, "section": [] }' >"$WORK/plan.json"
cat >"$WORK/existing.cron" <<'CRON'
0 1 * * * /bin/true # keep
0 4 * * * /usr/bin/zmsA --auto-best >/dev/null 2>&1
30 5 * * * /opt/zapret-manager-luci/backend.sh test_action auto_tick x >/dev/null 2>&1 # zm-autobest
CRON
ucode -L "$ROOT/forkop/files/usr/lib" "$UPDATES" refresh-cron-fixture "$WORK/plan.json" "$WORK/existing.cron" \
  /usr/bin/forkop '# list' '# subscription' '# component' >"$WORK/apply.json" ||
  fail 'the cron refresh fixture failed'
ucode -e '
  let r = json(require("fs").readfile(ARGV[0]));
  if (r.crontab != "0 1 * * * /bin/true # keep\n") die("crontab: " + r.crontab + "\n");
  let logged = false;
  for (let item in r.logs) if (index(item.message, "Zapret-Manager automatic strategy selection is disabled") == 0) logged = true;
  if (!logged) die("the removal is not logged\n");
' "$WORK/apply.json" || fail 'the cron refresh keeps the auto-best jobs'

echo 'zapret_manager_web: PASS'
