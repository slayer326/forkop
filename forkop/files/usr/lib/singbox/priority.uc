#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let process_identity = require("core.process_identity");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const SECTION_CACHE_DIR = getenv("FORKOP_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const PRIORITY_PID_FILE = getenv("FORKOP_PRIORITY_PID_FILE") || RUNTIME_STATE_DIR + "/priority.pid";
const PRIORITY_UC = getenv("FORKOP_PRIORITY_UC") || LIB_DIR + "/singbox/priority.uc";
const DIAGNOSTICS_UC = getenv("FORKOP_DIAGNOSTICS_UC") || LIB_DIR + "/diagnostics/runtime.uc";
const MANUAL_DIR = RUNTIME_STATE_DIR + "/priority-manual";
const SELECTION_LOCK = RUNTIME_STATE_DIR + "/priority-selection.lock";

function manual_path(group) {
    let name = hexenc(as_string(group.tag));
    return name != "" && length(name) <= 240 ? MANUAL_DIR + "/" + name + ".json" : "";
}

function member_level(group, tag) {
    for (let i = 0; i < length(group.levels); i++)
        if (index(group.levels[i].outbounds, tag) >= 0)
            return i;
    return -1;
}

function manual_choice(group) {
    let record = object_or_empty(read_json_file(manual_path(group)));
    let tag = as_string(record.tag);
    return record.group == group.tag && member_level(group, tag) >= 0 ? tag : "";
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_status(command) {
    let status = int(system(command));
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return command_status(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "forkop", "[" + level + "] priority: " + as_string(message) ]);
}

function now_seconds() {
    return int(clock()[0]);
}

function duration_to_milliseconds(value, fallback_ms) {
    let rest = as_string(value);
    if (rest == "")
        return fallback_ms;

    let total = 0.0;
    let multipliers = {
        ns: 0.000001,
        us: 0.001,
        ms: 1,
        s: 1000,
        m: 60000,
        h: 3600000,
        d: 86400000
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return fallback_ms;

        let token = as_string(matched[0]);
        total += (matched[1] * 1) * multipliers[matched[3]];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? fallback_ms : int(total + 0.5);
}

function duration_to_seconds(value, fallback_seconds) {
    let ms = duration_to_milliseconds(value, fallback_seconds * 1000);
    let seconds = int((ms + 999) / 1000);
    return seconds > 0 ? seconds : fallback_seconds;
}

function bool_value(value, fallback) {
    if (value == null || value == "")
        return !!fallback;
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function normalize_group(group, tag_name) {
    group = object_or_empty(group);
    let levels = [];
    for (let level in array_or_empty(group.levels)) {
        let outbounds = [];
        for (let outbound in array_or_empty(level.outbounds)) {
            outbound = as_string(outbound);
            if (outbound != "")
                push(outbounds, outbound);
        }
        if (length(outbounds) > 0) {
            push(levels, {
                id: as_string(level.id || ""),
                displayName: as_string(level.displayName || level.name || ""),
                order: int(level.order || 0),
                outbounds
            });
        }
    }

    return {
        id: as_string(group.id || ""),
        tag: as_string(group.tag || tag_name),
        section: as_string(group.section || ""),
        displayName: as_string(group.displayName || group.name || tag_name),
        health_url: as_string(group.health_url || "https://www.gstatic.com/generate_204"),
        active_check_interval: as_string(group.active_check_interval || "5s"),
        check_timeout: as_string(group.check_timeout || "2s"),
        recovery_check_interval: as_string(group.recovery_check_interval || "15s"),
        pick_fastest: bool_value(group.pick_fastest, false),
        switch_to_faster_same_priority: bool_value(group.switch_to_faster_same_priority, false),
        fastest_check_interval: as_string(group.fastest_check_interval || "3m"),
        levels
    };
}

function section_cache_files() {
    let result = [];
    for (let path in split(command_output_from_args([
        "find",
        SECTION_CACHE_DIR,
        "-mindepth",
        "1",
        "-maxdepth",
        "1",
        "-type",
        "f",
        "-name",
        "*.json"
    ]), "\n")) {
        path = as_string(path);
        if (path != "")
            push(result, path);
    }
    return result;
}

function priority_groups_from_cache() {
    let result = [];
    for (let path in section_cache_files()) {
        let cache = object_or_empty(read_json_file(path));
        for (let tag_name, group in object_or_empty(cache.priorityGroups)) {
            let normalized = normalize_group(group, tag_name);
            if (normalized.tag != "" && length(normalized.levels) > 0)
                push(result, normalized);
        }
    }
    return result;
}

function module_capture(args) {
    let output_path = trim(command_output_from_args([ "mktemp" ]));
    if (output_path == "")
        return { status: 1, output: "" };

    let command = command_from_args([ "ucode", "-L", LIB_DIR, DIAGNOSTICS_UC, "clash-api" ]);
    for (let arg in args)
        command += " " + shell_quote(arg);

    let status = command_status(command + " >" + shell_quote(output_path) + " 2>&1");
    let output = as_string(fs.readfile(output_path) || "");
    remove_file(output_path);
    return { status, output };
}

function parse_delay_output(output) {
    let value = null;
    try {
        value = json(output);
    }
    catch (e) {
        return null;
    }

    if (type(value) != "object")
        return null;

    let delay = value.delay;
    if (delay == null || as_string(delay) == "")
        return null;

    delay = int(delay, 10);
    return delay >= 0 ? delay : null;
}

function clash_probe(tag_name, group) {
    let timeout = as_string(duration_to_milliseconds(group.check_timeout, 2000));
    let result = module_capture([ "get_proxy_latency", tag_name, timeout, group.health_url ]);
    if (result.status != 0)
        return { alive: false, delay: 0 };

    let delay = parse_delay_output(result.output);
    if (delay == null)
        return { alive: false, delay: 0 };

    return { alive: true, delay };
}

function fixture_probe(latencies, tag_name) {
    let value = object_or_empty(latencies)[tag_name];
    if (value == null || as_string(value) == "" || int(value, 10) < 0)
        return { alive: false, delay: 0 };
    return { alive: true, delay: int(value, 10) };
}

function choose_from_level(group, level_index, probe, skip_tag) {
    let level = object_or_empty(array_or_empty(group.levels)[level_index]);
    let best = null;

    for (let tag_name in array_or_empty(level.outbounds)) {
        if (as_string(skip_tag) != "" && tag_name == skip_tag)
            continue;
        let result = probe(tag_name, group);
        if (!result.alive)
            continue;

        if (!group.pick_fastest)
            return {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };

        if (best == null || result.delay < best.delay)
            best = {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };
    }

    return best;
}

function choose_from_level_range(group, start_index, end_index, probe, skip_tag) {
    let levels = array_or_empty(group.levels);
    if (length(levels) == 0)
        return null;

    start_index = int(start_index || 0);
    end_index = int(end_index || 0);
    if (start_index < 0)
        start_index = 0;
    if (end_index >= length(levels))
        end_index = length(levels) - 1;
    if (start_index > end_index)
        return null;

    for (let i = start_index; i <= end_index; i++) {
        let selected = choose_from_level(group, i, probe, skip_tag);
        if (selected != null)
            return selected;
    }
    return null;
}

function choose_fastest_same_level(group, level_index, active_tag, probe) {
    let level = object_or_empty(array_or_empty(group.levels)[level_index]);
    let active = null;
    let best = null;

    for (let tag_name in array_or_empty(level.outbounds)) {
        let result = probe(tag_name, group);
        if (tag_name == active_tag)
            active = result;
        if (!result.alive)
            continue;
        if (best == null || result.delay < best.delay) {
            best = {
                tag: tag_name,
                levelIndex: level_index,
                delay: result.delay
            };
        }
    }

    if (best == null || best.tag == active_tag)
        return null;
    if (active == null || !active.alive || best.delay < active.delay)
        return best;
    return null;
}

function set_group_proxy(group, tag_name) {
    let result = module_capture([ "set_group_proxy", group.tag, tag_name, "" ]);
    return result.status == 0;
}

function selection_lock(acquire) {
    return command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc",
        acquire ? "acquire-runtime-dir-lock" : "release-runtime-dir-lock", SELECTION_LOCK,
        as_string(fs.readlink("/proc/self")) ]);
}

function manual_select_locked(group_tag, tag, automatic) {
    if (fs.stat(RUNTIME_STATE_DIR + "/stop.requested") != null) {
        write_json({ success: false, error: "Forkop was stopped" });
        return 1;
    }
    let group = null;
    for (let item in priority_groups_from_cache())
        if (item.tag == group_tag) group = item;
    if (group == null || (!automatic && member_level(group, tag) < 0)) {
        write_json({ success: false, error: "Unknown Priority group or member" });
        return 1;
    }
    let path = manual_path(group);
    if (path == "" || !ensure_dir(MANUAL_DIR)) return 1;
    let previous = fs.readfile(path);
    let stage = path + "." + as_string(fs.readlink("/proc/self")) + ".new";
    let stamp = clock();
    let revision = as_string(stamp[0]) + "." + as_string(stamp[1]) + "." + as_string(fs.readlink("/proc/self"));
    if (!fs.writefile(stage, sprintf("%J", { group: group.tag, tag: automatic ? "" : tag, revision })) || !fs.rename(stage, path)) {
        remove_file(stage);
        return 1;
    }
    if (automatic) {
        write_json({ success: true, mode: "auto" });
        return 0;
    }
    // Publish the request before the API call so an in-flight automatic probe
    // cannot overwrite a user's selection when it commits its result.
    if (!set_group_proxy(group, tag)) {
        if (manual_choice(group) == tag) {
            if (previous == null) remove_file(path);
            else if (fs.writefile(stage, previous)) fs.rename(stage, path);
        }
        remove_file(stage);
        return 1;
    }
    write_json({ success: true, mode: "manual", proxy: tag });
    return 0;
}

function manual_select(group_tag, tag, automatic) {
    if (!selection_lock(true)) {
        write_json({ success: false, error: "Priority selection is busy; retry" });
        return 1;
    }
    let status = manual_select_locked(group_tag, tag, automatic);
    selection_lock(false);
    return status;
}

function switch_group(state, group, selected) {
    if (selected == null || selected.tag == "")
        return false;

    if (manual_choice(group) != "")
        return false;

    if (state.active == selected.tag) {
        state.levelIndex = selected.levelIndex;
        state.activeDelay = selected.delay;
        state.failedChecks = 0;
        return true;
    }

    // Only the short controller commit is serialized. Network health probes
    // stay outside this lock so a user need not wait for a whole group scan.
    if (!selection_lock(true)) return false;
    if (manual_choice(group) != "") {
        selection_lock(false);
        return false;
    }
    let switched = set_group_proxy(group, selected.tag);
    selection_lock(false);
    if (!switched) {
        log_message("failed to switch " + group.tag + " to " + selected.tag, "warn");
        return false;
    }

    state.active = selected.tag;
    state.levelIndex = selected.levelIndex;
    state.activeDelay = selected.delay;
    state.failedChecks = 0;
    return true;
}

function init_group_state(group) {
    return {
        active: "",
        levelIndex: -1,
        activeDelay: 0,
        manualActive: "",
        manualRevision: "",
        failedChecks: 0,
        nextActiveCheck: now_seconds(),
        nextRecoveryCheck: now_seconds() + duration_to_seconds(group.recovery_check_interval, 15),
        nextFastestCheck: now_seconds() + duration_to_seconds(group.fastest_check_interval, 180)
    };
}

function tick_group(state, group) {
    let now = now_seconds();
    let manual = manual_choice(group);
    let record = object_or_empty(read_json_file(manual_path(group)));
    let revision = record.group == group.tag ? as_string(record.revision) : "";
    if (state.manualRevision != revision) {
        state.manualRevision = revision;
        // Auto must resync the controller even if the user pinned and released
        // a node between two worker ticks and manualActive was never observed.
        if (manual == "") {
            state.active = "";
            state.levelIndex = -1;
            state.nextActiveCheck = now;
            state.failedChecks = 0;
        }
    }
    if (manual != "") {
        state.manualActive = manual;
        state.active = manual;
        state.levelIndex = member_level(group, manual);
        state.failedChecks = 0;
        return;
    }
    if (state.manualActive != "") {
        state.manualActive = "";
        state.active = "";
        state.levelIndex = -1;
        state.nextActiveCheck = now;
        state.nextRecoveryCheck = now;
    }

    if (state.active == "" && now >= state.nextActiveCheck) {
        let selected = choose_from_level_range(group, 0, length(group.levels) - 1, clash_probe);
        switch_group(state, group, selected);
        state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
        return;
    }

    if (state.active != "" && now >= state.nextActiveCheck) {
        let active = clash_probe(state.active, group);
        if (active.alive) {
            state.activeDelay = active.delay;
            state.failedChecks = 0;
        }
        else {
            state.failedChecks++;
            // A single lost/slow health request is not enough to abandon a
            // working tunnel, especially while a mobile WAN is recovering.
            if (state.failedChecks < 2) {
                state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
                return;
            }
            let selected = choose_from_level_range(
                group,
                state.levelIndex,
                length(group.levels) - 1,
                clash_probe,
                state.active
            );
            if (switch_group(state, group, selected)) {
                state.failedChecks = 0;
                state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
                state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
            }
            else {
                state.active = "";
                state.levelIndex = -1;
            }
        }
        state.nextActiveCheck = now + duration_to_seconds(group.active_check_interval, 5);
    }

    if (state.active != "" && state.levelIndex > 0 && now >= state.nextRecoveryCheck) {
        let selected = choose_from_level_range(group, 0, state.levelIndex - 1, clash_probe);
        if (switch_group(state, group, selected))
            state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
        state.nextRecoveryCheck = now + duration_to_seconds(group.recovery_check_interval, 15);
    }

    if (state.active != "" && group.switch_to_faster_same_priority && now >= state.nextFastestCheck) {
        let selected = choose_fastest_same_level(group, state.levelIndex, state.active, clash_probe);
        if (selected != null)
            switch_group(state, group, selected);
        state.nextFastestCheck = now + duration_to_seconds(group.fastest_check_interval, 180);
    }
}

function worker() {
    let groups = priority_groups_from_cache();
    if (length(groups) == 0)
        return 0;

    let states = {};
    for (let group in groups)
        states[group.tag] = init_group_state(group);

    while (true) {
        for (let group in groups)
            tick_group(states[group.tag], group);
        system("sleep 1");
    }
}

function stop_runtime() {
    process_identity.signal(PRIORITY_PID_FILE, "ucode", [ "ucode", "-L", LIB_DIR, PRIORITY_UC, "worker" ], true, "TERM");
    remove_file(PRIORITY_PID_FILE);
    command_success_from_args([ "rm", "-rf", MANUAL_DIR ]);
    return 0;
}

function start_runtime() {
    let groups = priority_groups_from_cache();
    stop_runtime();
    if (length(groups) == 0)
        return 0;

    if (!ensure_dir(RUNTIME_STATE_DIR))
        return 1;

    let command = command_from_args([ "ucode", "-L", LIB_DIR, PRIORITY_UC, "worker" ]) +
        " >/dev/null 2>&1 1000>&- & echo $!";
    let pid = trim(command_output_from_args([ "sh", "-c", command ]));
    return process_identity.record(PRIORITY_PID_FILE, pid) ? 0 : 1;
}

function select_fixture(group_path, latency_path, start_index, end_index, skip_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let selected = choose_from_level_range(group, start_index, end_index, function(tag_name, _group) {
        return fixture_probe(latencies, tag_name);
    }, skip_tag);
    write_json(selected == null ? {} : selected);
}

function select_faster_fixture(group_path, latency_path, level_index, active_tag) {
    let group = normalize_group(read_json_file(group_path), "fixture");
    let latencies = object_or_empty(read_json_file(latency_path));
    let selected = choose_fastest_same_level(group, int(level_index || 0), as_string(active_tag), function(tag_name, _group) {
        return fixture_probe(latencies, tag_name);
    });
    write_json(selected == null ? {} : selected);
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "worker")
    exit(worker());
else if (mode == "manual-select")
    exit(manual_select(as_string(ARGV[1]), as_string(ARGV[2]), ARGV[3] == "auto"));
else if (mode == "tick-fixture") {
    let group = normalize_group(read_json_file(ARGV[1]), "fixture");
    let state = read_json_file(ARGV[2]) || init_group_state(group);
    tick_group(state, group);
    write_json(state);
}
else if (mode == "select-fixture")
    select_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "select-faster-fixture")
    select_faster_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else {
    warn("Usage: singbox/priority.uc <start-runtime|stop-runtime|worker|select-fixture|select-faster-fixture>\n");
    exit(1);
}
