#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let runtime_lock = require("core.runtime_lock");
let process_identity = require("core.process_identity");
let list_worker = require("core.list_worker");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function constant_value(name, fallback) {
    let value = constants[name];
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || constant_value("FORKOP_CONFIG_NAME", "forkop");
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN_PATH = getenv("FORKOP_BIN") || constant_value("FORKOP_BIN", "/usr/bin/forkop");
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || constant_value("FORKOP_SERVICE_INIT", "/etc/init.d/forkop");
const SERVICE_NAME = getenv("FORKOP_SERVICE_NAME") || constant_value("FORKOP_SERVICE_NAME", "forkop");
const CONFIG_FILE = getenv("FORKOP_CONFIG_FILE") || "/etc/config/" + CONFIG_NAME;
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const START_RETRY_FILE = getenv("FORKOP_START_RETRY_FILE") || RUNTIME_STATE_DIR + "/start.retry";
const START_RETRY_PID_FILE = getenv("FORKOP_START_RETRY_PID_FILE") || RUNTIME_STATE_DIR + "/start-retry.pid";
const START_FAILURE_FILE = getenv("FORKOP_START_FAILURE_FILE") || RUNTIME_STATE_DIR + "/start.failure";
const START_RETRY_DELAY_SECONDS = getenv("FORKOP_START_RETRY_DELAY_SECONDS") || "30";
// procd.sh holds its lock on fd 1000 for every init.d call, so start_service
// detaches the start and init.d exits 0 before the start has run (UC-013). A
// caller that needs the outcome runs start-and-wait: it passes a request id
// (FORKOP_START_REQUEST) through init.d, and the start worker writes its
// status to start-result.<id> in RUNTIME_STATE_DIR.
const START_WAIT_TIMEOUT_SECONDS = getenv("FORKOP_START_WAIT_TIMEOUT_SECONDS") || "300";
// Right after its result the start worker drains a reload queued during the
// start; a reload that restarts sing-box briefly takes the runtime out of
// "stably running".
const START_SETTLE_SECONDS = getenv("FORKOP_START_SETTLE_SECONDS") || "30";
// A package upgrade can start Forkop while the previous process is still
// completing a list-content reload.  Use the same inter-process lock as
// reload_service() so that start never classifies that expected transient as
// an orphaned sing-box process.
const START_RUNTIME_LOCK_WAIT_SECONDS = getenv("FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS") || "30";
// A start holds reload.lock for its whole duration, and so do a forced
// subscription update or the automatic latency test: a start that does not
// get the lock within that wait is deferred, not dropped. The start-retry
// worker runs it again after this delay, and that start waits for the lock
// again, until the holder has released it (UC-057).
const START_DEFERRED_RETRY_DELAY_SECONDS = getenv("FORKOP_START_DEFERRED_RETRY_DELAY_SECONDS") || "5";
// A stop takes the same lock, so the work that holds it (a subscription
// update, a DNS-failover apply, a start) finishes before the runtime is torn
// down. The wait is bounded: a stop must not fail because of a download. The
// stop request is recorded before the wait, and a holder that is still at
// work when the stop proceeds without the lock does not start the runtime
// again (service/state.uc runtime-apply-allowed; UC-012).
const STOP_RUNTIME_LOCK_WAIT_SECONDS = getenv("FORKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS") || "30";
const STOP_REQUESTED_FILE = getenv("FORKOP_STOP_REQUESTED_FILE") || RUNTIME_STATE_DIR + "/stop.requested";
// An explicit start since boot: written by every start that is asked for
// (start_service, already while it waits for reload.lock: the start at boot
// with autostart, a UI or CLI start or restart, init.d start or restart;
// service/lifecycle.uc start and restart; the package postinst for a Forkop
// that ran before the upgrade) and removed by the user's stop and by the
// removal of the package (service/package.uc prerm). Like the stop request
// it lives in runtime state and ends with a reboot. A runtime that is down
// without it was not started since boot, or the user stopped it: no reload,
// restore or list update starts it (D-15(a), UC-056). One that is down with
// it went down after an explicit start, and a reload repairs it.
const EXPLICIT_START_FILE = getenv("FORKOP_EXPLICIT_START_FILE") || RUNTIME_STATE_DIR + "/start.explicit";
const SERVICE_TRIGGER_SYNC_FILE = getenv("FORKOP_SERVICE_TRIGGER_SYNC_FILE") || RUNTIME_STATE_DIR + "/service-triggers.sync";
const INTERNAL_CONFIG_TRIGGER_GUARD = getenv("FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/forkop.internal-config-change";
const CONFIG_CHANGE_REASON = getenv("FORKOP_CONFIG_CHANGE_REASON") || "on_config_change";
// Reload reasons of callers that must tell a queued reload from a completed
// one: the list worker keeps its durable apply marker, a snapshot restore and
// an autotune apply never confirm a configuration the runtime has not loaded.
const QUEUE_ACK_REASONS = [ "list-content", "config-restore", "autotune" ];
// Reload reasons of the transactions that must also tell a reload that an
// explicit stop skipped: a snapshot restore and an autotune apply never
// report a runtime they did not reload (D-15, UC-056).
const STOP_ACK_REASONS = [ "config-restore", "autotune" ];

const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function shell_assignment(name, value) {
    print(as_string(name), "=", shell_quote(value), "\n");
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

function command_status(command) {
    return normalize_status(system(command));
}

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };

    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_status_from_args(args) {
    return command_status(command_from_args(args));
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in (type(args) == "array" ? args : []))
        push(result, arg);
    return result;
}

function module_command(module_path, args) {
    return command_from_args(module_args(module_path, args));
}

function module_status(module_path, args) {
    return command_status(module_command(module_path, args));
}

function module_output(module_path, args) {
    let result = command_capture(module_command(module_path, args));
    return result.status == 0 ? result.output : "";
}

function trim(value) {
    return replace(as_string(value), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function numeric_text(value) {
    return match(as_string(value), /^[0-9]+$/) != null;
}

function current_epoch() {
    return as_string(int(clock()[0]));
}

function bool_text(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return as_string(fallback);
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_executable(path) {
    return command_success_from_args([ "test", "-x", as_string(path) ]);
}

function unlink_file(path) {
    fs.unlink(as_string(path));
}

function ensure_parent_dir(path) {
    let dir = replace(as_string(path), /\/[^\/]*$/, "");
    if (dir == "" || dir == path)
        return true;
    return fs.mkdir(dir, 0755) || fs.stat(dir) != null;
}

function write_text_file(path, text) {
    return fs.writefile(as_string(path), as_string(text));
}

function first_line_value(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function config_file_hash(path) {
    let fields = split(trim(command_output_from_args([ "md5sum", as_string(path) ])), " ");
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

// The lock protocol and the owner record: core/runtime_lock.uc. Global lock
// order: service/state.uc. Only the owner releases its lock: a holder whose
// lock was taken over must not delete the new owner's lock.
function release_runtime_dir_lock(lock_dir, owner_pid) {
    return runtime_lock.release(lock_dir, owner_pid);
}

function acquire_runtime_dir_lock(lock_dir, owner_pid) {
    return runtime_lock.acquire(lock_dir, owner_pid);
}

function acquire_runtime_dir_lock_wait(lock_dir, owner_pid, timeout) {
    timeout = int(timeout || 0);
    let started_at = int(current_epoch(), 10) || 0;

    while (!acquire_runtime_dir_lock(lock_dir, owner_pid)) {
        let now = int(current_epoch(), 10) || started_at;
        if (now - started_at >= timeout)
            return false;
        command_success_from_args([ "sleep", "1" ]);
    }

    return true;
}

// Every request rewrites the marker with a unique request id, so a caller
// comparing markers sees a second request even within the same second.
function mark_pending_reload(path, reason) {
    path = as_string(path || PENDING_RELOAD_FILE);
    reason = as_string(reason || "pending");

    if (!ensure_parent_dir(path))
        return false;

    let now = clock();
    let request = sprintf("%s.%d.%09d", as_string(fs.readlink("/proc/self") || "0"), now[0], now[1]);
    return write_text_file(path, "reason=" + reason + "\nupdated_at=" + as_string(int(now[0])) + "\nrequest=" + request + "\n");
}

function mark_start_retry(path, reason) {
    path = as_string(path || START_RETRY_FILE);
    reason = as_string(reason || "start_failed");

    if (!ensure_parent_dir(path))
        return false;

    return write_text_file(path, "reason=" + reason + "\nupdated_at=" + current_epoch() + "\n");
}

// The retry of a deferred start (start_service) records the stop request
// that preceded the start: only a stop requested after the start wins over
// the retry (D-15, UC-012). The start was requested explicitly, so its retry
// does not depend on autostart either.
function mark_deferred_start_retry(stop_request) {
    if (!ensure_parent_dir(START_RETRY_FILE))
        return false;

    return write_text_file(START_RETRY_FILE, "reason=start_deferred\nupdated_at=" + current_epoch() +
        "\nstop_request=" + as_string(stop_request) + "\n");
}

// The stop request that a deferred start followed ("" for none), or null
// when no deferred start is pending: a start that ran since served it, a
// stop cancelled it.
function deferred_start_stop_request() {
    let data = fs.readfile(START_RETRY_FILE);
    if (data == null || match(data, /(^|\n)reason=start_deferred(\n|$)/) == null)
        return null;
    let recorded = match(data, /(^|\n)stop_request=([^\n]*)/);
    return recorded == null ? "" : recorded[2];
}

// Who asked for a stop, recorded with it as "by=<source>". "package" (the
// package maintainer scripts) and "component" (a component change) stop
// Forkop for a start that follows; any other stop is the user's. Only the
// user's stop is shown as one (service/ui.uc, diagnostics/runtime.uc): an
// internal stop whose start never came is a failure. A stop made while the
// user's stop is in effect stays the user's. Reloads are held off alike
// (D-15, UC-056). service/lifecycle.uc records the same.
function stop_request_source() {
    let source = as_string(getenv("FORKOP_STOP_SOURCE"));
    if (source != "package" && source != "component")
        return "user";
    let previous = fs.readfile(STOP_REQUESTED_FILE);
    if (previous == null)
        return source;
    let by = match(previous, /(^|\n)by=([a-z]*)/);
    return by == null || by[2] == "user" ? "user" : source;
}

// Removed only by an explicit start or restart (start_service,
// service/lifecycle.uc): until then no reload brings the runtime back (D-15,
// UC-056). Each request is distinct, so a start can tell a stop requested
// while it waited for reload.lock from an earlier one (its first line). The
// user's stop also ends the explicit start; Forkop's own stop for a package
// or component change is followed by a start and keeps it.
function mark_stop_requested() {
    if (!ensure_parent_dir(STOP_REQUESTED_FILE))
        return false;
    let now = clock();
    let source = stop_request_source();
    let written = write_text_file(STOP_REQUESTED_FILE, sprintf("%d.%09d.%s\nby=%s\n", now[0], now[1],
        as_string(fs.readlink("/proc/self")), source));
    if (source == "user")
        unlink_file(EXPLICIT_START_FILE);
    return written;
}

function stop_requested() {
    return file_exists(STOP_REQUESTED_FILE);
}

function mark_explicit_start() {
    if (!ensure_parent_dir(EXPLICIT_START_FILE))
        return false;
    let now = clock();
    return write_text_file(EXPLICIT_START_FILE, sprintf("%d.%09d.%s\n", now[0], now[1],
        as_string(fs.readlink("/proc/self"))));
}

function explicit_start_recorded() {
    return file_exists(EXPLICIT_START_FILE);
}

// Nobody asks for the runtime to run: a stop holds it down, or no explicit
// start was made since boot (EXPLICIT_START_FILE). A runtime that is down
// then stays down until an explicit start (D-15(a), UC-056).
function start_not_requested() {
    return stop_requested() || !explicit_start_recorded();
}

function stop_request_value() {
    if (!stop_requested())
        return "";
    return first_line_value(STOP_REQUESTED_FILE) || "requested";
}

// An explicit stop outlasts a pending start retry (UC-012), except the
// retry of a start that was requested after that stop and deferred.
function start_retry_stop_requested() {
    if (!stop_requested())
        return false;
    let deferred_after = deferred_start_stop_request();
    return deferred_after == null || stop_request_value() != deferred_after;
}

// A deferred start is still to run: requested, and no stop won over it. A
// package upgrade stops Forkop for a start that follows (service/package.uc).
function deferred_start_pending() {
    return deferred_start_stop_request() != null && !start_retry_stop_requested();
}

function clear_start_retry(path) {
    path = as_string(path || START_RETRY_FILE);
    if (file_exists(path))
        unlink_file(path);
}

function start_retry_pending(path) {
    return file_exists(as_string(path || START_RETRY_FILE));
}

function start_failure_blocks_retry(path) {
    return file_exists(as_string(path || START_FAILURE_FILE));
}

// The scheduled retry is `/bin/sh -c <script> sh <delay>`, recorded by pid
// and start ticks and recognized by that command line
// (core/process_identity.uc). A PID that a killed retry left in its pidfile
// and another process now holds is neither signalled nor taken for a
// scheduled retry (UC-014).
const START_RETRY_SHELL = "/bin/sh";

function start_retry_argv(path) {
    // The retry is not the start a start-and-wait caller waits for, nor is
    // it tracked by the UI job that waited for that start: that job may have
    // ended, and the retried start opens a job of its own
    // (begin_external_service_action).
    return [ START_RETRY_SHELL, "-c", "unset FORKOP_START_REQUEST FORKOP_UI_ACTION_TRACKED; sleep \"$1\"; " +
        command_from_args([ "rm", "-f", path ]) + "; exec " + command_from_args([ SERVICE_INIT, "retry_start_on_wan_up" ]) ];
}

// The executable of the retry is what /bin/sh resolves to (busybox on
// OpenWrt).
function start_retry_executable() {
    return as_string(fs.realpath(START_RETRY_SHELL)) || START_RETRY_SHELL;
}

function cancel_scheduled_start_retry(path) {
    path = as_string(path || START_RETRY_PID_FILE);
    process_identity.signal(path, start_retry_executable(), start_retry_argv(path), false, "TERM");
    if (file_exists(path))
        unlink_file(path);
}

// init.d disable: autostart no longer applies, so the scheduled retry of a
// failed start ends. A deferred start was requested explicitly and does not
// depend on autostart (retry_start_on_wan_up): disabling autostart is no
// stop, and its retry stays scheduled.
function cancel_autostart_start_retry(path) {
    if (deferred_start_stop_request() == null)
        cancel_scheduled_start_retry(path);
}

function schedule_start_retry(path, delay_seconds) {
    path = as_string(path || START_RETRY_PID_FILE);
    delay_seconds = as_string(delay_seconds || START_RETRY_DELAY_SECONDS);
    if (!numeric_text(delay_seconds))
        delay_seconds = "30";

    if (process_identity.matches(path, start_retry_executable(), start_retry_argv(path), false, false) != "")
        return true;
    if (file_exists(path))
        unlink_file(path);
    if (!ensure_parent_dir(path))
        return false;

    let worker = start_retry_argv(path);
    push(worker, "sh", delay_seconds);
    let result = command_capture(command_from_args(worker) + " >/dev/null 2>&1 & echo $!");
    let pid = trim(result.output);
    if (result.status != 0 || !numeric_text(pid))
        return false;

    return process_identity.record(path, pid);
}

// A start-and-wait result: "status=<N>", or "status=deferred" while the
// start waits for its retry (start_service).
function read_start_result(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;
    data = trim(data);
    if (data == "status=deferred")
        return "deferred";
    let matched = match(data, /^status=([0-9]+)$/);
    return matched != null ? int(matched[1], 10) : null;
}

function write_start_result(path, value) {
    let tmp = path + "." + as_string(fs.readlink("/proc/self")) + ".tmp";
    if (!ensure_parent_dir(path) || !write_text_file(tmp, "status=" + as_string(value) + "\n"))
        return false;
    if (fs.rename(tmp, path))
        return true;
    unlink_file(tmp);
    return false;
}

// A caller whose start was deferred gets the outcome of the start that runs
// next (its retry, or any other start that got reload.lock first) or of the
// stop that cancelled the retry.
function resolve_deferred_start_results(status) {
    for (let name in (fs.lsdir(RUNTIME_STATE_DIR) || [])) {
        if (index(name, "start-result.") != 0 || match(name, /\.tmp$/) != null)
            continue;
        let path = RUNTIME_STATE_DIR + "/" + name;
        if (read_start_result(path) === "deferred")
            write_start_result(path, int(status));
    }
}

// Ends a pending start retry. A start deferred meanwhile has either written
// its result already, which this resolves, or schedules its retry after this
// (start_service).
function drop_start_retry(status) {
    clear_start_retry(START_RETRY_FILE);
    cancel_scheduled_start_retry(START_RETRY_PID_FILE);
    resolve_deferred_start_results(status);
}

// A list update runs its DNS probe and downloads without reload.lock
// (UC-057), but it reads its sources when it starts and applies them in its
// final reload. A reload that ran meanwhile would start a list update that
// the running one refuses, while the running one discards its generation for
// the changed sources; or it would try to apply the new sources before their
// generation exists. Reloads that arrive while the list worker runs are
// queued, as when it held reload.lock for the whole update, and the worker
// runs them when it ends (finish_list_update). The worker's record:
// core/list_worker.uc.
function list_update_worker_running() {
    return list_worker.running(LIB_DIR);
}

function consume_pending_reload(path) {
    path = as_string(path || PENDING_RELOAD_FILE);
    if (!file_exists(path))
        return false;

    unlink_file(path);
    return true;
}

function run_pending_reload_if_requested(path, init_script) {
    path = as_string(path || PENDING_RELOAD_FILE);
    init_script = as_string(init_script || SERVICE_INIT);

    if (!consume_pending_reload(path))
        return true;

    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Applying pending Forkop reload" ]);
    // Wait for the nested init.d reload to claim and finish the handoff.
    // Detaching here would consume reload.pending before that process owns
    // reload.lock, allowing another worker to win the gap.
    // The nested init.d is waited for, so it keeps the procd service lock of
    // this process (fd 1000): rc.common then takes it from the inherited
    // descriptor. Closing fd 1000, as detached workers must, makes the child
    // open the lock anew and wait for its own waiting ancestor.
    if (system(shell_quote(init_script) + " reload pending </dev/null >/dev/null 2>&1") != 0) {
        mark_pending_reload(path, "pending_handoff_failed");
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[warn] Pending Forkop reload handoff failed; request was retained" ]);
        return false;
    }

    return true;
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function settings_from_fixture(path) {
    let data = fs.readfile(path);
    if (data == null)
        return {};
    try {
        data = json(data);
    }
    catch (e) {
        return {};
    }
    return object_or_empty(object_or_empty(data).settings);
}

function initd_service_trigger_sync_requested(path) {
    path = as_string(path);
    if (!file_exists(path))
        return false;

    let value = first_line_value(path);
    unlink_file(path);
    return value == "1";
}

function initd_guard_matches_current_config(guard_path, config_path, now_value) {
    let guard_timestamp = first_line_value(guard_path);
    if (!numeric_text(guard_timestamp))
        return false;

    now_value = now_value == null ? current_epoch() : as_string(now_value);
    if (!numeric_text(now_value))
        return true;

    if (int(now_value, 10) - int(guard_timestamp, 10) > 30)
        return false;

    let data = fs.readfile(guard_path);
    if (data == null)
        return false;

    let lines = split(data, "\n");
    let guard_hash = length(lines) > 1 ? as_string(lines[1]) : "";
    if (guard_hash == "")
        return false;

    return guard_hash == config_file_hash(config_path);
}

function initd_should_skip_internal_config_reload(reason, guard_path, config_path, expected_reason, now_value) {
    if (as_string(reason) != as_string(expected_reason || CONFIG_CHANGE_REASON))
        return false;
    if (!file_exists(as_string(guard_path)))
        return false;

    let matches = initd_guard_matches_current_config(guard_path, config_path, now_value);
    unlink_file(guard_path);
    return matches;
}

function initd_should_restore_dnsmasq_on_start_from_value(reason, shutdown_correctly) {
    if (as_string(reason) == "triggered")
        return false;

    shutdown_correctly = as_string(shutdown_correctly);
    if (shutdown_correctly == "")
        shutdown_correctly = "1";
    return shutdown_correctly == "0";
}

function initd_should_ignore_config_change_reload(reason, expected_reason, runtime_running, service_enabled) {
    return as_string(reason) == as_string(expected_reason || CONFIG_CHANGE_REASON) &&
        !bool_text(runtime_running);
}

function initd_should_queue_config_change_reload(reason, expected_reason, runtime_running, active_service_action) {
    return as_string(reason) == as_string(expected_reason || CONFIG_CHANGE_REASON) &&
        !bool_text(runtime_running) &&
        as_string(active_service_action) != "";
}

function initd_should_sync_service_triggers(reason, expected_reason, sync_file) {
    if (as_string(reason) != as_string(expected_reason || CONFIG_CHANGE_REASON))
        return false;
    return initd_service_trigger_sync_requested(sync_file);
}

function restore_dnsmasq_failsafe() {
    if (!file_exists(DNS_APPLY_UC))
        return 0;
    return module_status(DNS_APPLY_UC, [ "failsafe-restore" ]);
}

// This ucode process. `sh -c 'echo $PPID'` names it only when /bin/sh execs
// its last command (busybox ash); dash reports a shell that has exited.
function owner_pid_value() {
    let pid = as_string(fs.readlink("/proc/self"));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function begin_external_service_action(action, source, owner_pid) {
    if (as_string(getenv("FORKOP_UI_ACTION_TRACKED") || "0") == "1")
        return "";
    if (!file_exists(UI_UC))
        return "";

    let job_id = trim(module_output(UI_UC, [ "service-action-begin-if-idle", action, source || "initd" ]));
    if (job_id != "")
        module_status(UI_UC, [ "service-action-update-pid", job_id, owner_pid || owner_pid_value() ]);

    return job_id;
}

function finish_external_service_action(action, job_id, status) {
    if (as_string(job_id) == "" || !file_exists(UI_UC))
        return 0;
    return module_status(UI_UC, [ "service-action-finish-after-command", action, job_id, as_string(status) ]);
}

function runtime_status_object() {
    let data = command_output_from_args([ BIN_PATH, "get_status" ]);
    try {
        data = json(data);
    }
    catch (e) {
        return {};
    }
    return object_or_empty(data);
}

function runtime_is_running() {
    return bool_text(runtime_status_object().running);
}

function status_service() {
    if (runtime_is_running()) {
        print("running\n");
        return 0;
    }

    print("not running\n");
    return 1;
}

function service_is_enabled() {
    return file_exists("/etc/rc.d/S99" + SERVICE_NAME);
}

function retry_start_on_wan_up_action(runtime_running_value, service_enabled_value, retry_pending_value, stop_requested_value) {
    if (bool_text(runtime_running_value))
        return "skip_running";
    // An explicit stop outlasts a retry of a start it interrupted (UC-012).
    if (bool_text(stop_requested_value))
        return "skip_stopped";
    if (!bool_text(service_enabled_value))
        return "skip_disabled";
    if (!bool_text(retry_pending_value))
        return "skip_no_retry";
    return "start";
}

function retry_start_on_wan_up(owner_pid) {
    // A deferred start was requested explicitly: its retry does not depend
    // on autostart, and only a stop requested after it wins.
    let deferred = deferred_start_stop_request() != null;
    let action = retry_start_on_wan_up_action(
        runtime_is_running() ? "1" : "0",
        (deferred || service_is_enabled()) ? "1" : "0",
        start_retry_pending(START_RETRY_FILE) ? "1" : "0",
        start_retry_stop_requested() ? "1" : "0"
    );

    if (action == "skip_stopped" && start_retry_pending(START_RETRY_FILE))
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Automatic Forkop start retry skipped: Forkop was stopped" ]);
    if (action == "skip_running" || action == "skip_disabled" || action == "skip_stopped") {
        clear_start_retry(START_RETRY_FILE);
        resolve_deferred_start_results(action == "skip_running" ? 0 : 1);
        return 0;
    }

    if (action != "start")
        return 0;

    // Not logged: a holder may keep reload.lock for long, and the log says
    // when the deferred start runs (start_service).
    if (deferred) {
        let status = command_status_from_args([ SERVICE_INIT, "start", "deferred" ]);
        if (status != 0) {
            command_success_from_args([ "logger", "-t", SERVICE_NAME, "[error] Deferred Forkop start request failed with status " + status ]);
            resolve_deferred_start_results(status);
        }
        return status;
    }

    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Retrying failed Forkop start after WAN came up" ]);
    // A failed cold start has no Forkop runtime to tear down. Re-enter the
    // guarded start path so foreign/ambiguous sing-box processes remain
    // untouched instead of using restart's destructive stop phase.
    // init.d only accepts the detached start here; the start worker logs
    // whether the runtime recovered (start_service, reason "triggered").
    let status = command_status_from_args([ SERVICE_INIT, "start", "triggered" ]);
    if (status != 0)
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[error] Forkop automatic recovery request failed with status " + status ]);
    return status;
}

function badwan_interface_monitored(settings, interface_name) {
    settings = object_or_empty(settings);
    if (option(settings, "enable_badwan_interface_monitoring", "") != "1")
        return false;

    let interfaces = split(replace(trim(option(settings, "badwan_monitored_interfaces", "")), /[ \t\r\n]+/g, " "), " ");
    for (let iface in interfaces)
        if (trim(iface) == interface_name)
            return true;
    return false;
}

function wan_up_action(runtime_running_value, service_enabled_value, retry_pending_value, monitoring_value, stop_requested_value) {
    if (bool_text(runtime_running_value))
        return bool_text(monitoring_value) ? "reload" : "skip_running";
    return retry_start_on_wan_up_action(runtime_running_value, service_enabled_value, retry_pending_value, stop_requested_value);
}

function handle_wan_up(owner_pid) {
    let settings = uci_settings();
    let running = runtime_is_running() ? "1" : "0";
    let action = wan_up_action(
        running,
        (deferred_start_stop_request() != null || service_is_enabled()) ? "1" : "0",
        start_retry_pending(START_RETRY_FILE) ? "1" : "0",
        badwan_interface_monitored(settings, "wan") ? "1" : "0",
        start_retry_stop_requested() ? "1" : "0"
    );

    if (action == "reload") {
        drop_start_retry(0);
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Reloading Forkop after monitored WAN came up" ]);
        return command_status_from_args([ SERVICE_INIT, "reload", "badwan_interface_up" ]);
    }

    if (action == "skip_running" || action == "skip_stopped") {
        drop_start_retry(action == "skip_running" ? 0 : 1);
        return 0;
    }

    return retry_start_on_wan_up(owner_pid);
}

function active_service_action_value() {
    if (!file_exists(UI_UC))
        return "";

    return trim(module_output(UI_UC, [ "active-service-action" ]));
}

function ui_action_tracked() {
    return as_string(getenv("FORKOP_UI_ACTION_TRACKED") || "0") == "1";
}

function start_plan_value(reason, owner_pid, settings, bin_ok) {
    settings = object_or_empty(settings);
    let job_id = begin_external_service_action("start", "initd", owner_pid);
    bin_ok = bin_ok == null ? file_executable(BIN_PATH) : bool_text(bin_ok);

    if (!bin_ok) {
        restore_dnsmasq_failsafe();
        finish_external_service_action("start", job_id, 1);
    }

    return {
        job_id,
        bin_ok
    };
}

function start_plan(reason, owner_pid, settings, bin_ok) {
    let plan = start_plan_value(reason, owner_pid, settings, bin_ok);
    shell_assignment("INITD_UI_JOB_ID", plan.job_id);
    shell_assignment("INITD_BIN_OK", plan.bin_ok ? "1" : "0");
}

function start_request_value() {
    let request = as_string(getenv("FORKOP_START_REQUEST") || "");
    return match(request, /^[A-Za-z0-9._-]+$/) != null ? request : "";
}

function start_result_path(request) {
    return RUNTIME_STATE_DIR + "/start-result." + as_string(request);
}

// The outcome of this start for the start-and-wait caller that requested it,
// and for the WAN-up retry (reason "triggered") in the log. Written before a
// queued reload is drained: that reload waits for procd's lock, which the
// caller may hold while it waits for this result. A start that an explicit
// stop skipped or overtook is no failed recovery: the stop wins (UC-012).
function report_start_result(reason, status, stopped) {
    if (as_string(reason) == "triggered" && !(status != 0 && stopped)) {
        if (status == 0)
            command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Forkop recovered automatically after a failed start" ]);
        else
            command_success_from_args([ "logger", "-t", SERVICE_NAME, "[error] Forkop automatic recovery attempt failed; see the preceding startup logs" ]);
    }

    resolve_deferred_start_results(status);
    let request = start_request_value();
    if (request == "")
        return;
    write_start_result(start_result_path(request), int(status));
}

// reload.lock stayed busy for the whole wait: long work holds it (a forced
// subscription update, the automatic latency test, a cold start). The start
// is not dropped: the start-retry worker runs it again (reason "deferred")
// until it gets the lock or a stop cancels it (retry_start_on_wan_up). Its
// start-and-wait caller learns "deferred" and waits for the outcome of the
// start that runs. The result is written before the retry is scheduled: a
// stop or start that drops the retry meanwhile either resolves the result or
// leaves this retry in place (drop_start_retry).
function defer_start(reason, stop_request_before) {
    let request = start_request_value();
    if (request != "")
        write_start_result(start_result_path(request), "deferred");
    if (!mark_deferred_start_retry(stop_request_before) ||
        !schedule_start_retry(START_RETRY_PID_FILE, START_DEFERRED_RETRY_DELAY_SECONDS)) {
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[error] Forkop start could not get the runtime lock, and its retry could not be scheduled" ]);
        report_start_result(reason, 1);
        return 1;
    }
    // Logged once: the retries of the deferred start are not.
    if (as_string(reason) != "deferred")
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[warn] Forkop start deferred: another operation held the runtime lock for " +
            START_RUNTIME_LOCK_WAIT_SECONDS + " s; the start runs once the lock is released" ]);
    return 1;
}

// Without an owner (the detached init.d start, whose rc.common shell exits
// at once) this process owns reload.lock and the UI job: it runs `forkop
// start` and releases the lock itself, so the owner lives for the whole
// start (UC-010).
function start_service(reason, owner_pid) {
    print("Start Forkop\n");
    reason = as_string(reason);
    owner_pid = as_string(owner_pid) || owner_pid_value();
    // A stop requested after this start (for the automatic retry: at all)
    // wins over it: the stop may have run while this start waited for
    // reload.lock, or runs next (UC-012). The retry of a deferred start
    // compares with the stop request that preceded the start it retries, and
    // does nothing once that start was served or cancelled.
    let stop_request_before = reason == "triggered" ? "" : stop_request_value();
    if (reason == "deferred") {
        stop_request_before = deferred_start_stop_request();
        if (stop_request_before == null)
            return 0;
    }
    // The explicit start is recorded when it is asked for, before it waits
    // for reload.lock, and also when it then fails: a runtime that is down
    // after it did not stay down on request, and a reload repairs it. So is
    // one whose start is deferred behind a long holder of the lock, or never
    // gets the lock (its retry could not be scheduled, its worker died): the
    // start was asked for, not "not started since boot" (D-15(a), UC-056).
    // A stop requested after this start ends it again (mark_stop_requested).
    if (!stop_requested() || stop_request_value() == stop_request_before)
        mark_explicit_start();
    if (!acquire_runtime_dir_lock_wait(RELOAD_LOCK_DIR, owner_pid, START_RUNTIME_LOCK_WAIT_SECONDS)) {
        if (stop_requested() && stop_request_value() != stop_request_before) {
            command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Forkop start skipped: a stop was requested after it" ]);
            report_start_result(reason, 1, true);
            return 1;
        }
        if (reason == "deferred" && deferred_start_stop_request() == null)
            return 0;
        return defer_start(reason, stop_request_before);
    }
    if (stop_requested() && stop_request_value() != stop_request_before) {
        release_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid);
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Forkop start skipped: a stop was requested after it" ]);
        report_start_result(reason, 1, true);
        return 1;
    }
    if (reason == "deferred") {
        if (deferred_start_stop_request() == null) {
            release_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid);
            return 0;
        }
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Running the deferred Forkop start: the runtime lock was released" ]);
    }
    // An explicit start ends an explicit stop; a stop request seen after
    // this point was made during this start. The start that runs is recorded
    // again, in case its record went away while it waited for the lock.
    mark_explicit_start();
    unlink_file(STOP_REQUESTED_FILE);

    let plan = start_plan_value(reason, owner_pid, uci_settings(), null);
    if (!plan.bin_ok) {
        release_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid);
        report_start_result(reason, 1);
        return 1;
    }

    let status = command_status_from_args([ BIN_PATH, "start" ]);
    // This start served a start deferred meanwhile: its retry ends before
    // reload.lock is released, or it may take the lock next, still find its
    // record and start Forkop once more.
    if (status == 0)
        drop_start_retry(0);
    release_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid);
    report_start_result(reason, status, stop_requested());
    if (status == 0) {
        // A reload requested during the start was queued behind reload.lock.
        // A service action drains the queue when it finishes; without one,
        // the start is the last holder and applies it, as a reload does.
        if (file_exists(PENDING_RELOAD_FILE) && active_service_action_value() == "")
            run_pending_reload_if_requested(PENDING_RELOAD_FILE, SERVICE_INIT);
    }
    else if (stop_requested()) {
        // The start was abandoned for, or overtaken by, an explicit stop.
        drop_start_retry(status);
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Forkop start did not complete because a stop was requested; no automatic retry" ]);
    }
    else if (start_failure_blocks_retry(START_FAILURE_FILE)) {
        drop_start_retry(status);
        // A start refused for a guard that a failed transition kept: no
        // retry succeeds before a restart removes it (service/lifecycle.uc).
        if (index(as_string(fs.readfile(START_FAILURE_FILE)), "reason=runtime_guard_active") >= 0)
            command_success_from_args([ "logger", "-t", SERVICE_NAME, "[error] Forkop startup retry suppressed: a failed transition kept its fail-closed guard (runtime_guard_active); restart Forkop to recover" ]);
        else
            command_success_from_args([ "logger", "-t", SERVICE_NAME, "[error] Forkop startup retry suppressed because all rule-set download sources failed; see the fatal startup error in LuCI logs" ]);
    }
    else {
        mark_start_retry(START_RETRY_FILE, as_string(reason) == "triggered" ? "wan_retry_failed" : "start_failed");
        schedule_start_retry(START_RETRY_PID_FILE, START_RETRY_DELAY_SECONDS);
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[warn] Forkop start failed; scheduled an automatic retry" ]);
    }
    finish_external_service_action("start", plan.job_id, status);
    return status;
}

// A start reports its result also when its caller has stopped waiting; any
// waiter reads its result within a second, so an older one has no reader.
function remove_stale_start_results() {
    let oldest = int(current_epoch(), 10) - int(START_WAIT_TIMEOUT_SECONDS, 10);
    for (let name in (fs.lsdir(RUNTIME_STATE_DIR) || [])) {
        if (index(name, "start-result.") != 0)
            continue;
        let path = RUNTIME_STATE_DIR + "/" + name;
        let info = fs.lstat(path);
        if (info != null && info.type == "file" && int(info.mtime) < oldest)
            unlink_file(path);
    }
}

// Runs `init.d start|restart` and waits (bounded) for the start worker's
// result, then checks that the runtime runs: init.d under procd returns 0
// before the start has run. For callers that act on the outcome (component
// actions, the package postinst, UI actions). Waiting outside init.d keeps
// procd's lock free for the start worker and other service calls. A start
// deferred for reload.lock is no failure: the wait goes on for the start
// that runs, and the UI job `ui_job` (service/ui.uc) says that it waits.
function start_and_wait(action, reason, timeout, ui_job) {
    action = as_string(action);
    if (action != "start" && action != "restart")
        return 2;
    timeout = as_string(timeout);
    timeout = numeric_text(timeout) ? int(timeout, 10) : int(START_WAIT_TIMEOUT_SECONDS, 10);

    remove_stale_start_results();
    let now = clock();
    let request = sprintf("%s.%d.%09d", owner_pid_value(), now[0], now[1]);
    let path = start_result_path(request);
    unlink_file(path);

    let args = [ "env", "FORKOP_START_REQUEST=" + request, SERVICE_INIT, action ];
    if (as_string(reason) != "")
        push(args, as_string(reason));
    let status = command_status(command_from_args(args) + " </dev/null >/dev/null 2>&1");

    let result = read_start_result(path);
    let deadline = int(current_epoch(), 10) + timeout;
    let deferred = false;
    while (status == 0 && (result == null || result === "deferred") && int(current_epoch(), 10) < deadline) {
        if (result === "deferred" && !deferred) {
            deferred = true;
            if (as_string(ui_job) != "" && file_exists(UI_UC))
                command_success_from_args(module_args(UI_UC, [ "service-action-deferred", as_string(ui_job) ]));
        }
        command_success_from_args([ "sleep", "1" ]);
        result = read_start_result(path);
    }
    unlink_file(path);

    if (status != 0)
        return status;
    if (result === "deferred") {
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[warn] Forkop " + action + " was deferred for the runtime lock and did not run within " + as_string(timeout) + " s" ]);
        print("pending\n");
        return 1;
    }
    if (result == null) {
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[warn] Forkop " + action + " did not report its result within " + as_string(timeout) + " s" ]);
        // The start may still be at work: a caller with a shorter bound (the
        // package postinst) tells this from a failed start.
        print("pending\n");
        return 1;
    }
    if (result != 0)
        return result;
    let settle = numeric_text(START_SETTLE_SECONDS) ? int(START_SETTLE_SECONDS, 10) : 30;
    let settle_deadline = int(current_epoch(), 10) + settle;
    while (!runtime_is_running()) {
        if (int(current_epoch(), 10) >= settle_deadline)
            return 1;
        command_success_from_args([ "sleep", "1" ]);
    }
    return 0;
}

function stop_plan(owner_pid, bin_ok) {
    let job_id = begin_external_service_action("stop", "initd", owner_pid);
    bin_ok = bin_ok == null ? file_executable(BIN_PATH) : bool_text(bin_ok);

    if (!bin_ok) {
        restore_dnsmasq_failsafe();
        finish_external_service_action("stop", job_id, 1);
    }

    shell_assignment("INITD_UI_JOB_ID", job_id);
    shell_assignment("INITD_BIN_OK", bin_ok ? "1" : "0");
}

function stop_finish(job_id, status) {
    status = int(status || 0);
    // Exit 2 means lifecycle refused an ambiguous process owner before any
    // teardown ran. DNS still belongs to the runtime that is serving it, so
    // do not swap in the failsafe under a working dataplane.
    if (status != 0 && status != 2)
        restore_dnsmasq_failsafe();
    finish_external_service_action("stop", job_id, status);
    return status;
}

// This process owns reload.lock for the stop: it runs `forkop stop` and
// releases the lock itself.
function stop_service(owner_pid) {
    mark_stop_requested();
    // The stop wins over a pending retry, and over a deferred start whose
    // caller still waits for it.
    drop_start_retry(1);
    let job_id = begin_external_service_action("stop", "initd", owner_pid);
    if (!file_executable(BIN_PATH)) {
        restore_dnsmasq_failsafe();
        finish_external_service_action("stop", job_id, 1);
        return 1;
    }

    let lock_owner = owner_pid_value();
    let locked = acquire_runtime_dir_lock_wait(RELOAD_LOCK_DIR, lock_owner, STOP_RUNTIME_LOCK_WAIT_SECONDS);
    if (!locked)
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[warn] Forkop stop did not get the runtime lock within " + STOP_RUNTIME_LOCK_WAIT_SECONDS + " s; stopping without it, the work that holds it will not start the runtime again" ]);
    // A start that held reload.lock meanwhile and failed, or one that did not
    // get it, may have scheduled its retry before it saw this stop request.
    drop_start_retry(1);
    let status = command_status_from_args([ BIN_PATH, "stop" ]);
    if (locked)
        release_runtime_dir_lock(RELOAD_LOCK_DIR, lock_owner);
    return stop_finish(job_id, status);
}

// No reload, whoever requests it, starts a runtime that an explicit stop took
// down, nor one that nobody started since boot (D-15(a), UC-056); a runtime
// that went down after an explicit start is still left to the reload to
// repair. Decided before a UI job is opened: a reload that does nothing must
// not show the stopped Forkop as "reloading" and then fail to reach a running
// runtime. service/lifecycle.uc checks the same under reload.lock.
function reload_skipped_after_stop(reason, runtime_running_value) {
    if (!start_not_requested())
        return false;
    if (runtime_running_value == null ? runtime_is_running() : bool_text(runtime_running_value))
        return false;
    command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Reload '" + as_string(reason) +
        (stop_requested() ? "' skipped: Forkop was stopped; only a start brings its runtime back" :
            "' skipped: Forkop was not started since boot; only a start starts it") ]);
    return true;
}

function reload_begin_value(reason, owner_pid, runtime_running_value, service_enabled_value, active_service_action) {
    reason = as_string(reason);

    if (initd_should_skip_internal_config_reload(
        reason,
        INTERNAL_CONFIG_TRIGGER_GUARD,
        CONFIG_FILE,
        CONFIG_CHANGE_REASON,
        null
    )) {
        return { action: "skip", job_id: "" };
    }

    // Not a queued request either: the next start applies everything.
    if (reload_skipped_after_stop(reason, runtime_running_value))
        return { action: "skip", job_id: "", stopped: true };

    active_service_action = active_service_action == null ? active_service_action_value() : as_string(active_service_action);
    let running = runtime_running_value == null ? runtime_is_running() : bool_text(runtime_running_value);
    let enabled = service_enabled_value == null ? service_is_enabled() : bool_text(service_enabled_value);
    let queue_config_change = initd_should_queue_config_change_reload(reason, CONFIG_CHANGE_REASON, running, active_service_action);

    if (!queue_config_change && initd_should_ignore_config_change_reload(reason, CONFIG_CHANGE_REASON, running, enabled))
        return { action: "skip", job_id: "" };

    // Only a reload that could run or be queued reaches the ownership gate.
    // In particular, D-15 above keeps its `stopped` result even when an
    // unrelated/foreign sing-box process exists, while an ignored config
    // trigger remains a no-op. Never queue work with ambiguous ownership.
    if (module_status(LIB_DIR + "/service/state.uc", [ "sing-box-process-conflict" ]) == 0) {
        command_success_from_args([ "logger", "-t", SERVICE_NAME, "[fatal] Refusing Forkop reload: sing-box process ownership is ambiguous; preserving the existing runtime" ]);
        return { action: "reject", job_id: "", conflict: true };
    }

    if (reason == "pending" && active_service_action != "" && !ui_action_tracked()) {
        mark_pending_reload(PENDING_RELOAD_FILE, reason);
        return { action: "skip", job_id: "", queued: true };
    }

    if (reason == "pending") {
        if (list_update_worker_running() || !acquire_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid || owner_pid_value())) {
            mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_busy");
            return { action: "skip", job_id: "", queued: true };
        }

        unlink_file(SERVICE_TRIGGER_SYNC_FILE);
        let job_id = begin_external_service_action("reload", "initd", owner_pid);
        return { action: "run", job_id };
    }

    if (queue_config_change) {
        mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_queued");
        return { action: "skip", job_id: "", queued: true };
    }

    if (list_update_worker_running() || !acquire_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid || owner_pid_value())) {
        // A stop under way (its request is recorded, the runtime is not down
        // yet) drops what is queued for the runtime it takes down
        // (service/lifecycle.uc stop()): not queued, and a transaction caller
        // is told "stopped", not "queued" (D-15, UC-056).
        if (stop_requested()) {
            command_success_from_args([ "logger", "-t", SERVICE_NAME, "[info] Reload '" + reason +
                "' not queued: Forkop is being stopped; only a start brings its runtime back" ]);
            return { action: "skip", job_id: "", stopped: true };
        }
        mark_pending_reload(PENDING_RELOAD_FILE, reason || "reload_busy");
        return { action: "skip", job_id: "", queued: true };
    }

    unlink_file(SERVICE_TRIGGER_SYNC_FILE);
    let job_id = begin_external_service_action("reload", "initd", owner_pid);
    return { action: "run", job_id };
}

function reload_begin(reason, owner_pid, runtime_running_value, service_enabled_value) {
    let plan = reload_begin_value(reason, owner_pid, runtime_running_value, service_enabled_value, null);
    shell_assignment("INITD_RELOAD_ACTION", plan.action);
    if (plan.action == "run")
        shell_assignment("INITD_UI_JOB_ID", plan.job_id);
    return 0;
}

function reload_finish_value(reason, job_id, status, owner_pid) {
    status = int(status || 0);
    finish_external_service_action("reload", job_id, status);
    let sync = status == 0 && initd_should_sync_service_triggers(reason, CONFIG_CHANGE_REASON, SERVICE_TRIGGER_SYNC_FILE);
    release_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid);
    if (active_service_action_value() == "")
        run_pending_reload_if_requested(PENDING_RELOAD_FILE, SERVICE_INIT);
    return { status, sync };
}

function reload_finish(reason, job_id, status, owner_pid) {
    let plan = reload_finish_value(reason, job_id, status, owner_pid);
    shell_assignment("INITD_SYNC_SERVICE_TRIGGERS", plan.sync ? "1" : "0");
    return plan.status;
}

function reload_service(reason, owner_pid) {
    let plan = reload_begin_value(reason, owner_pid, null, null);
    if (plan.conflict)
        return 1;
    // The job of a UI reload (service/ui.uc) reports what happened to it as
    // well: a reload only queued behind the operation that holds reload.lock
    // is not a completed one (UC-061).
    let tracked = ui_action_tracked();
    let stop_ack = index(STOP_ACK_REASONS, as_string(reason)) >= 0 || tracked;
    if (plan.action != "run") {
        // Callers of QUEUE_ACK_REASONS must distinguish an accepted queued
        // request from a completed lifecycle; for them a skip is a queued
        // request, and for STOP_ACK_REASONS a skip after an explicit stop is
        // "stopped". A UI-tracked caller is told both, and "queued" only for
        // a skip that queued the request. Ordinary callers keep no output
        // and status 0.
        if (plan.stopped && stop_ack)
            print("stopped\n");
        else if (!plan.stopped && (index(QUEUE_ACK_REASONS, as_string(reason)) >= 0 || (tracked && plan.queued)))
            print("queued\n");
        return 0;
    }

    // The public CLI enters this function too. Once initd owns reload.lock,
    // call lifecycle directly rather than re-entering `forkop reload`.
    let status = command_status(command_from_args([ "env", "FORKOP_UI_ACTION_TRACKED=1", "ucode", "-L", LIB_DIR,
        LIB_DIR + "/service/lifecycle.uc", "reload", reason ]) + " >/dev/null 2>&1");
    let finish = reload_finish_value(reason, plan.job_id, status, owner_pid || owner_pid_value());
    // A stop requested after the check above, or a runtime not started since
    // boot that went down after it: the lifecycle skipped the reload under
    // reload.lock, or the runtime it reloaded is down again. Either way no
    // runtime runs the new configuration.
    if (status == 0 && stop_ack && start_not_requested() && !runtime_is_running())
        print("stopped\n");
    else if (finish.sync)
        print("sync\n");
    return finish.status;
}

// Without an owner, the caller's own lock (the init.d shell that ran
// reload-service): core/runtime_lock.uc.
function reload_release(owner_pid) {
    release_runtime_dir_lock(RELOAD_LOCK_DIR, owner_pid);
    return 0;
}

function trigger_plan(settings) {
    settings = object_or_empty(settings);
    let badwan_enabled = option(settings, "enable_badwan_interface_monitoring", "") == "1";
    let badwan_interfaces = split(replace(trim(option(settings, "badwan_monitored_interfaces", "")), /[ \t\r\n]+/g, " "), " ");
    let delay = option(settings, "badwan_reload_delay", "2000");
    if (delay == "")
        delay = "2000";

    print("delay\t", delay, "\n");
    print("config\tconfig.change\t", CONFIG_NAME, "\t", SERVICE_INIT, "\treload\t", CONFIG_CHANGE_REASON, "\n");
    print("interface\tinterface.*.up\twan\t", SERVICE_INIT, "\thandle_wan_up\t\n");

    // The reload for a monitored interface coming up carries the same reason
    // as the one for wan (handle_wan_up): a reload that procd requests on its
    // own does not start a runtime that was explicitly stopped (UC-012).
    if (badwan_enabled) {
        for (let iface in badwan_interfaces) {
            iface = trim(iface);
            if (iface == "" || iface == "wan")
                continue;
            print("interface\tinterface.*.up\t", iface, "\t", SERVICE_INIT, "\treload\tbadwan_interface_up\n");
        }
    }
}

let mode = ARGV[0] || "";

if (mode == "restore-dnsmasq-failsafe")
    exit(restore_dnsmasq_failsafe());
else if (mode == "runtime-running")
    exit(runtime_is_running() ? 0 : 1);
else if (mode == "status-service")
    exit(status_service());
else if (mode == "retry-start-on-wan-up")
    exit(retry_start_on_wan_up(ARGV[1]));
else if (mode == "handle-wan-up")
    exit(handle_wan_up(ARGV[1]));
else if (mode == "retry-start-on-wan-up-action")
    print(retry_start_on_wan_up_action(ARGV[1], ARGV[2], ARGV[3], ARGV[4]), "\n");
else if (mode == "wan-up-action")
    print(wan_up_action(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]), "\n");
else if (mode == "service-enabled")
    exit(service_is_enabled() ? 0 : 1);
else if (mode == "mark-start-retry")
    exit(mark_start_retry(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "clear-start-retry")
    clear_start_retry(ARGV[1]);
else if (mode == "start-retry-pending")
    exit(start_retry_pending(ARGV[1]) ? 0 : 1);
else if (mode == "start-failure-blocks-retry")
    exit(start_failure_blocks_retry(ARGV[1]) ? 0 : 1);
else if (mode == "schedule-start-retry")
    exit(schedule_start_retry(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "cancel-scheduled-start-retry")
    cancel_autostart_start_retry(ARGV[1]);
else if (mode == "deferred-start-pending")
    exit(deferred_start_pending() ? 0 : 1);
// service/package.uc postinst: the restart of a Forkop that ran before the
// upgrade, or ("if-running") a runtime that runs across it, is an explicit
// start; the previous version may have kept no record of it.
else if (mode == "mark-explicit-start")
    exit((ARGV[1] == "if-running" && !runtime_is_running()) || mark_explicit_start() ? 0 : 1);
// service/package.uc prerm: no start follows the removal of the package.
else if (mode == "clear-explicit-start")
    unlink_file(EXPLICIT_START_FILE);
else if (mode == "begin-action") {
    let job_id = begin_external_service_action(ARGV[1], ARGV[2] || "initd", ARGV[3]);
    if (job_id != "")
        print(job_id, "\n");
}
else if (mode == "finish-action")
    exit(finish_external_service_action(ARGV[1], ARGV[2], ARGV[3]));
else if (mode == "start-plan")
    start_plan(ARGV[1], ARGV[2], uci_settings(), null);
else if (mode == "start-service")
    exit(start_service(ARGV[1], ARGV[2]));
else if (mode == "start-and-wait")
    exit(start_and_wait(ARGV[1], ARGV[2], ARGV[3], ARGV[4]));
else if (mode == "start-plan-fixture") {
    let settings = {
        shutdown_correctly: ARGV[2],
        enable_badwan_interface_monitoring: ARGV[3],
        badwan_monitored_interfaces: ARGV[4]
    };
    start_plan(ARGV[1], ARGV[5] || "0", settings, ARGV[6] == null ? "1" : ARGV[6]);
}
else if (mode == "stop-plan")
    stop_plan(ARGV[1], null);
else if (mode == "stop-plan-fixture")
    stop_plan(ARGV[1] || "0", ARGV[2] == null ? "1" : ARGV[2]);
else if (mode == "stop-finish")
    exit(stop_finish(ARGV[1], ARGV[2]));
else if (mode == "stop-service")
    exit(stop_service(ARGV[1]));
else if (mode == "reload-begin")
    exit(reload_begin(ARGV[1], ARGV[2], null, null));
else if (mode == "reload-begin-fixture") {
    let plan = reload_begin_value(ARGV[1], ARGV[2] || "0", ARGV[3], ARGV[4], ARGV[5]);
    shell_assignment("INITD_RELOAD_ACTION", plan.action);
    if (plan.action == "run")
        shell_assignment("INITD_UI_JOB_ID", plan.job_id);
    exit(plan.action == "run" ? 0 : 1);
}
else if (mode == "reload-finish")
    exit(reload_finish(ARGV[1], ARGV[2], ARGV[3], ARGV[4]));
else if (mode == "reload-service")
    exit(reload_service(ARGV[1], ARGV[2]));
else if (mode == "reload-release")
    exit(reload_release(ARGV[1]));
else if (mode == "trigger-plan")
    trigger_plan(uci_settings());
else if (mode == "trigger-plan-fixture")
    trigger_plan(settings_from_fixture(ARGV[1]));
else if (mode == "initd-service-trigger-sync-requested")
    exit(initd_service_trigger_sync_requested(ARGV[1]) ? 0 : 1);
else if (mode == "initd-guard-matches-current-config")
    exit(initd_guard_matches_current_config(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "initd-should-skip-internal-config-reload")
    exit(initd_should_skip_internal_config_reload(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
else if (mode == "initd-should-restore-dnsmasq-on-start-fixture")
    exit(initd_should_restore_dnsmasq_on_start_from_value(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "initd-should-ignore-config-change-reload")
    exit(initd_should_ignore_config_change_reload(ARGV[1], ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
else if (mode == "initd-should-queue-config-change-reload")
    exit(initd_should_queue_config_change_reload(ARGV[1], ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
else if (mode == "initd-should-sync-service-triggers")
    exit(initd_should_sync_service_triggers(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else {
    warn("Usage: service/initd.uc <operation> ...\n");
    exit(1);
}
