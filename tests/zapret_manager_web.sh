#!/bin/sh
set -eu
# Installing Zapret-Manager from Forkop also activates its web version ("w"
# in the script) and keeps the Forkop mirror launchers; removal takes the web
# version along. Zapret-Manager's automatic strategy selection stays off:
# Forkop installs no zmsA launcher and removes the auto-best cron jobs, on
# install and on every cron refresh. Adapted from Forkop X 2.5.0 (c0861b65).
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
const ZAPRET_MANAGER_WEB_BACKEND = "/usr/libexec/rpcd/zapret-manager";
const ZAPRET_MANAGER_WEB_SCRIPT = "/opt/zapret-manager-luci/backend.sh";
const ZAPRET_MANAGER_CRONTAB = "/etc/crontabs/root";
` + constant("ZAPRET_MANAGER_AUTOBEST_MARKERS") + `
let tmp_dir = "/t", files = {}, downloads = [], runs = [], crontabs = [], logs = [], download_ok = true, installer_ok = true;
let installer_text = "#!/bin/sh\\nread -r _ _ V <<EOF\\n# Version: 4.62\\nEOF\\n";
function as_string(v) { return v == null ? "" : "" + v; }
function shell_quote(v) { return "\x27" + v + "\x27"; }
function read_file(p) { return files[p] || ""; }
function write_file(p, v) { files[p] = v; return true; }
function file_exists(p) { return files[p] != null; }
function remove_file(p) { delete files[p]; }
function make_tmp_file(prefix) { return "/t/" + prefix; }
function updates_log(m, level) { push(logs, m); }
function command_from_args(a) { return join(" ", a); }
function command_success_from_args(a) {
    if (a[0] == "crontab") { push(crontabs, files[a[1]]); files["/etc/crontabs/root"] = files[a[1]]; }
    return true;
}
function download_with_retry(url, path, label) {
    push(downloads, url);
    if (download_ok) files[path] = installer_text;
    return download_ok;
}
function run_logged(d, command) {
    push(runs, command);
    if (installer_ok) {
        files[ZAPRET_MANAGER_WEB_BACKEND] = "x";
        files[ZAPRET_MANAGER_WEB_SCRIPT] = "ZM_VERSION=\\"4.62\\"\\n";
    }
    return installer_ok;
}
` + join("\n", map([ "zapret_manager_web_installed_version", "zapret_manager_version_newer",
    "zapret_manager_web_url", "activate_zapret_manager_web", "zapret_manager_launcher",
    "write_zapret_manager_launchers", "zapret_manager_launcher_owned",
    "crontab_without_zapret_manager_autobest", "disable_zapret_manager_autobest" ], extract)) + `
let script = "ZM_LUCI_URL=\\"$" + "{GH_RAW}/Screamshow/Zapret-Manager/main/ZapretManager_LuCI.sh\\"; ZM_LUCI_CACHE=x\\n";
function reset() { files = {}; downloads = []; runs = []; crontabs = []; logs = []; download_ok = true; installer_ok = true; }

assert(zapret_manager_version_newer("4.62", "4.6") && zapret_manager_version_newer("4.10", "4.9"), "newer");
assert(!zapret_manager_version_newer("4.62", "4.62") && !zapret_manager_version_newer("4.5", "4.62"), "not newer");

reset();
assert(activate_zapret_manager_web(script) == "", "fresh activation failed");
assert(downloads[0] == "https://mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/ZapretManager_LuCI.sh", "installer URL: " + downloads[0]);
assert(length(runs) == 1 && index(runs[0], "sh /t/ZapretManager_LuCI.sh") == 0 && index(runs[0], "</dev/null") > 0, "installer not run non-interactively: " + runs[0]);
assert(!file_exists("/t/ZapretManager_LuCI.sh"), "installer left in tmp");

runs = [];
assert(activate_zapret_manager_web(script) == "" && length(runs) == 0, "an up-to-date web version was reinstalled");
assert(!file_exists("/t/ZapretManager_LuCI.sh"), "installer left in tmp when up to date");

files[ZAPRET_MANAGER_WEB_SCRIPT] = "ZM_VERSION=\\"4.50\\"\\n"; runs = [];
assert(activate_zapret_manager_web(script) == "" && length(runs) == 1, "an older web version was not updated");

reset(); installer_ok = false;
assert(index(activate_zapret_manager_web(script), "installer failed") >= 0, "installer failure not reported");
reset(); download_ok = false;
assert(index(activate_zapret_manager_web(script), "could not be downloaded") >= 0, "download failure not reported");
reset();
assert(activate_zapret_manager_web("no installer here") != "" && length(downloads) == 0, "script without ZM_LUCI_URL");

reset();
assert(write_zapret_manager_launchers("https://mirror.test/m.sh", zapret_manager_web_url(script)), "launchers");
assert(index(files["/usr/bin/zms"], "https://mirror.test/m.sh") > 0 && index(files["/usr/bin/zms"], "ZAPRET_MANAGER_MIRROR") > 0, "zms launcher");
assert(index(files["/usr/bin/zmw"], "ZapretManager_LuCI.sh") > 0, "zmw launcher");
assert(!file_exists("/usr/bin/zmsA"), "the auto-best launcher zmsA must not be installed");

assert(zapret_manager_launcher_owned("exec sh <(wget -q -O - https://mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh)"), "mirror launcher");
assert(zapret_manager_launcher_owned("sh <(wget -q -O - https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh) \\"$@\\""), "launcher the script writes");
assert(!zapret_manager_launcher_owned("#!/bin/sh\\nmy own zms\\n"), "user launcher would be removed");

reset();
files["/etc/crontabs/root"] = "0 1 * * * /bin/true # keep\\n0 4 * * * /usr/bin/zmsA --auto-best >/dev/null 2>&1\\n30 5 * * * /opt/zapret-manager-luci/backend.sh test_action auto_tick x >/dev/null 2>&1 # zm-autobest\\n*/5 * * * * /opt/zapret-manager-luci/backend.sh zm_watch >/dev/null 2>&1 # zm-rpcd-watch\\n";
assert(disable_zapret_manager_autobest(), "auto-best not disabled");
assert(files["/etc/crontabs/root"] == "0 1 * * * /bin/true # keep\\n*/5 * * * * /opt/zapret-manager-luci/backend.sh zm_watch >/dev/null 2>&1 # zm-rpcd-watch\\n", "crontab: " + files["/etc/crontabs/root"]);
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

# The web installer may overwrite zms; Forkop writes its mirror launchers
# after it, removes a zmsA, and disables auto-best.
awk '
  /^function install_zapret_manager\(/ { f = 1 }
  f && /activate_zapret_manager_web\(/ && !web { web = NR }
  f && /write_zapret_manager_launchers\(/ && !launch { launch = NR }
  f && /remove_file\("\/usr\/bin\/zmsA"\)/ && !zmsa { zmsa = NR }
  f && /disable_zapret_manager_autobest\(\)/ && !autobest { autobest = NR }
  f && /^}/ { exit }
  END { exit !(web && launch > web && zmsa > launch && autobest > launch) }
' "$ACTION" || fail 'install order: web version, launchers, zmsA removal, auto-best'
if awk '/^function install_zapret_manager\(/,/^}/' "$ACTION" | grep -q 'write_file("/usr/bin/zmsA"'; then
  fail 'install must not write zmsA'
fi

# Removal refuses a foreign launcher before it removes anything.
awk '
  /^function remove_zapret_manager\(/ { f = 1 }
  f && /zapret_manager_launcher_owned/ && !own { own = NR }
  f && /remove_zapret_manager_web\(\)/ && !web { web = NR }
  f && /remove_file\(path\)/ && !rm { rm = NR }
  f && /^}/ { exit }
  END { exit !(own && web > own && rm > web) }
' "$ACTION" || fail 'removal order: ownership check, web version, launchers'
grep -Fq 'uci -q delete uhttpd.zmweb && uci -q commit uhttpd' "$ACTION" ||
  fail 'the web version removal does not drop its uhttpd instance'

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
