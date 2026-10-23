#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = env("FORKOP_CONFIG_NAME", "forkop");
const CONFIG_PATH = env("FORKOP_CONFIG_PATH", "/etc/config/forkop");
const DEFAULT_CONFIG_PATH = env("FORKOP_DEFAULT_CONFIG_PATH", "/usr/share/forkop/defaults/forkop");
const RT_TABLES_PATH = env("FORKOP_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("FORKOP_BIN", "/usr/bin/forkop");
const INIT_PATH = env("FORKOP_INIT", "/etc/init.d/forkop");
const LIB_DIR = env("FORKOP_LIB", "/usr/lib/forkop");
const DNS_APPLY_UC = env("FORKOP_DNS_APPLY_UC", "/usr/lib/forkop/dns/apply.uc");
const SING_BOX_INIT = env("FORKOP_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("FORKOP_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("FORKOP_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Forkop managed sing-box service for binary variants");
const PACKAGE_UPGRADE_STATE = env("FORKOP_PACKAGE_UPGRADE_STATE", "/tmp/forkop-package-was-running");
const UPGRADE_SING_BOX_WAIT_SECONDS = int(env("FORKOP_UPGRADE_SING_BOX_WAIT_SECONDS", "15"));
// The start after an upgrade runs while the package manager holds its lock;
// a slow cold start must not hold the package operation up for the start's
// full timeout. The start carries on after this bound, logs its outcome and
// schedules its own retry.
const POSTINST_START_WAIT_SECONDS = env("FORKOP_POSTINST_START_WAIT_SECONDS", "60");
const PROC_DIR = env("FORKOP_PROC_DIR", "/proc");
const COMPONENT_UPDATE_CHECK_CACHE_DIR = env("FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR", "/var/run/forkop/component-update-checks");
const COMPONENT_UPDATE_CHECK_STATE_FILE = env("FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE", "/var/run/forkop/component-update-check.timestamp");
const PACKAGE_TEST_MODE = env("FORKOP_PACKAGE_TEST_MODE", "") != "";

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

// Status and standard output (stderr discarded).
function command_capture_from_args(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return { status: 1, output: "" };
    let output = as_string(pipe.read("all"));
    return { status: normalize_status(pipe.close()), output };
}

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, slash + 1) : path;
}

// A package replacement renames the executable link of an already running
// sing-box to "sing-box (deleted)". That process still holds the runtime, so
// the upgrade must keep counting it instead of concluding it has exited.
function sing_box_exe_path(path) {
    let basename = path_basename(path);
    return basename == "sing-box" || basename == "sing-box (deleted)";
}

function sing_box_process_count() {
    let count = 0;
    for (let exe_path in fs.glob(PROC_DIR + "/[0-9]*/exe"))
        if (sing_box_exe_path(as_string(fs.readlink(exe_path))))
            count++;
    return count;
}

function wait_for_upgrade_sing_box_exit() {
    let timeout = UPGRADE_SING_BOX_WAIT_SECONDS;

    // prerm stops the old service, but its sing-box child exits asynchronously.
    // postinst would otherwise reach the guarded start while that process is
    // still present, and the start refuses an ambiguous runtime by design -
    // leaving Forkop stopped after an ordinary package upgrade. Wait for the
    // process to leave on its own; never kill anything by name.
    while (sing_box_process_count() > 0) {
        if (timeout <= 0)
            return false;
        command_success_from_args([ "sleep", "1" ]);
        timeout--;
    }

    return true;
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function clear_component_update_check_cache() {
    for (let path in fs.glob(COMPONENT_UPDATE_CHECK_CACHE_DIR + "/*"))
        unlink_if_exists(path);
    unlink_if_exists(COMPONENT_UPDATE_CHECK_STATE_FILE);
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 forkop") >= 0) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || fs.writefile(RT_TABLES_PATH, join("\n", lines)) != null;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    if (path_exists(DNS_APPLY_UC))
        command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (data == null || index(data, SING_BOX_MANAGED_MARKER) < 0)
        return;

    command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function remember_upgrade_state(action) {
    // An explicit removal is unambiguous: nothing should be restored later.
    if (as_string(action) == "remove") {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        return;
    }

    // opkg invokes prerm without an action argument on some OpenWrt 24 builds,
    // including an ordinary version upgrade. Treating an empty action as "not
    // an upgrade" erased the only hand-off telling postinst to restart a
    // service that prerm had just stopped, so the router came back with Forkop
    // down. Service state is authoritative here: record a restart only when
    // Forkop was actually running immediately before prerm, or a start
    // deferred for reload.lock was still to run: the stop below cancels it.
    if (command_success_from_args([ INIT_PATH, "status" ]) ||
        command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "deferred-start-pending" ]))
        fs.writefile(PACKAGE_UPGRADE_STATE, "1\n");
    else
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
}

function prerm_cleanup(action) {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    remember_upgrade_state(action);
    if (!PACKAGE_TEST_MODE) {
        // Forkop's own stop for the package change, not the user's
        // (service/initd.uc stop_request_source).
        command_success_from_args([ "env", "FORKOP_STOP_SOURCE=package", INIT_PATH, "stop" ]);
        // No start follows a removal: the explicit start ends with it, and
        // a reinstall that does not start Forkop shows it not started, not
        // as a start that failed (service/initd.uc EXPLICIT_START_FILE;
        // D-15(a)).
        if (as_string(action) == "remove")
            command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "clear-explicit-start" ]);
        restore_dnsmasq_if_needed();
        // A managed binary variant is not owned by the Forkop APK. Keep its
        // init script and executable across a backend upgrade so postinst can
        // restart the same working core. Only uninstall removes them.
        if (as_string(action) == "remove")
            remove_managed_sing_box();
    }
    return remove_rt_tables_entry();
}

function postinst_restore() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    clear_component_update_check_cache();

    let config = fs.readfile(CONFIG_PATH);
    if (config == null || trim(as_string(config)) == "") {
        let defaults = fs.readfile(DEFAULT_CONFIG_PATH);
        if (defaults == null || trim(as_string(defaults)) == "") {
            warn("Unable to restore missing Forkop configuration: packaged defaults are unavailable.\n");
            return false;
        }
        if (fs.writefile(CONFIG_PATH, defaults) == null ||
            !command_success_from_args([ "chmod", "0644", CONFIG_PATH ])) {
            warn("Unable to restore missing Forkop configuration.\n");
            return false;
        }
    }

    if (!uci_core.load(CONFIG_NAME) || !uci_core.exists(CONFIG_NAME + ".settings")) {
        warn("Forkop configuration is invalid or unavailable to UCI.\n");
        return false;
    }

    // Only an explicit start since boot lets a reload start a runtime that
    // is down (service/initd.uc EXPLICIT_START_FILE; D-15(a)), and a previous
    // version kept no record of its start. A runtime that runs across the
    // upgrade (no prerm stopped it) was started explicitly; so was Forkop
    // that ran before the upgrade, whose restart below is an explicit start
    // also when it does not come or fails.
    let initd_module = LIB_DIR + "/service/initd.uc";
    if (!path_exists(PACKAGE_UPGRADE_STATE)) {
        command_success_from_args([ "ucode", "-L", LIB_DIR, initd_module, "mark-explicit-start", "if-running" ]);
        return true;
    }
    command_success_from_args([ "ucode", "-L", LIB_DIR, initd_module, "mark-explicit-start" ]);

    if (!wait_for_upgrade_sing_box_exit()) {
        warn("Timed out waiting for the previous Forkop sing-box runtime to exit; startup was not attempted.
");
        return false;
    }

    // The hand-off is consumed before the start, whatever its outcome: opkg
    // configures a package whose postinst failed again on every later
    // install, and such a re-run must neither wait for the runtime that came
    // up meanwhile nor start a Forkop that was stopped since.
    unlink_if_exists(PACKAGE_UPGRADE_STATE);

    // init.d exits 0 under procd before the detached start has run: wait for
    // the start's own result (service/initd.uc start-and-wait, UC-013) to
    // report a failure. It does not fail the package operation, as with
    // OpenWrt's default postinst: a failed start schedules its own retry,
    // and the in-app upgrade checks the runtime itself.
    let started = command_capture_from_args([ "env", "FORKOP_SERVICE_INIT=" + INIT_PATH,
        "ucode", "-L", LIB_DIR, LIB_DIR + "/service/initd.uc", "start-and-wait", "start", "",
        POSTINST_START_WAIT_SECONDS ]);
    if (started.status != 0 && match(started.output, /(^|\n)pending\n/) != null)
        warn("Forkop is still starting after the package upgrade; see the Forkop log for its outcome.\n");
    else if (started.status != 0)
        warn("Forkop did not start after the package upgrade; see the Forkop log.\n");
    return true;
}

function luci_cache_globs() {
    let configured = env("FORKOP_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "forkop", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup(ARGV[1]) ? 0 : 1);
else if (mode == "postinst")
    exit(postinst_restore() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else if (mode == "sing-box-exe-path-fixture")
    exit(sing_box_exe_path(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|postinst|remove-rt-tables-entry|luci-postinst>\n");
    exit(1);
}
