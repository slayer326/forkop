let fs = require("fs");
let process_identity = require("core.process_identity");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let words = [];
    for (let arg in args)
        push(words, shell_quote(arg));
    return join(" ", words);
}

function command_success(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function pidfiles(path) {
    if (fs.stat(path) == null)
        return [];
    let stream = fs.popen(command_from_args([ "find", path, "-maxdepth", "1", "-type", "f", "-name", "*.pid" ]), "r");
    if (stream == null)
        return [];
    let result = [];
    let line;
    while ((line = stream.read("line")) != null) {
        line = trim(line);
        if (line != "")
            push(result, line);
    }
    stream.close();
    return result;
}

function running(pid) {
    if (match(as_string(pid), /^[0-9]+$/) == null || !command_success([ "kill", "-0", pid ]))
        return false;
    let stat = fs.readfile("/proc/" + pid + "/stat");
    return stat != null && !match(stat, /\) Z /);
}

function snapshot(pid_dir, child_pid_dir, runtime_path, library_path, output_path) {
    let entries = [];
    for (let child_file in pidfiles(child_pid_dir)) {
        let child = process_identity.read_record(child_file);
        if (child == null)
            return false;
        if (running(child.pid)) {
            let parent_file = pid_dir + "/" + replace(child_file, /^.*\//, "");
            let parent = process_identity.read_record(parent_file);
            if (parent == null || !running(parent.pid))
                return false;
        }
    }
    for (let pidfile in pidfiles(pid_dir)) {
        let saved = process_identity.read_record(pidfile);
        if (saved == null)
            return false;
        let pid = saved.pid;
        let name = replace(replace(pidfile, /^.*\//, ""), /\.pid$/, "");
        if (!running(pid)) {
            let child_file = child_pid_dir + "/" + name + ".pid";
            let child = fs.stat(child_file) == null ? null : process_identity.read_record(child_file);
            if (fs.stat(child_file) != null && (child == null || running(child.pid)))
                return false;
            push(entries, { stale: name });
            continue;
        }
        if (saved.ticks != "" && process_identity.start_ticks(pid) != saved.ticks)
            return false;
        if (process_identity.matches(pidfile, "ucode",
            [ "ucode", "-L", library_path, runtime_path, "supervisor", name ], false, false) != pid)
            return false;
        let raw = fs.readfile("/proc/" + pid + "/cmdline");
        if (raw == null)
            return false;
        let args = split(raw, "\0");
        if (length(args) > 0 && args[length(args) - 1] == "")
            pop(args);
        if (length(args) != 9 ||
            !match(args[0], /(^|\/)ucode$/) || args[1] != "-L" ||
            args[2] != library_path || args[3] != runtime_path ||
            args[4] != "supervisor" || args[5] != name ||
            args[8] != child_pid_dir + "/" + name + ".pid")
            return false;
        push(entries, { name, args });
    }
    return fs.writefile(output_path, sprintf("%J\n", entries)) != null;
}

function valid_entries(input_path, child_pid_dir, runtime_path, library_path) {
    let data = fs.readfile(input_path);
    if (data == null)
        return null;
    let entries;
    try { entries = json(data); }
    catch (e) { return null; }
    if (type(entries) != "array")
        return null;
    let names = {};
    for (let entry in entries) {
        if (type(entry) != "object" || length(keys(entry)) != 2 || entry.stale != null)
            return null;
        let name = entry && entry.name;
        let args = entry && entry.args;
        if (type(name) != "string" || !match(name, /^[A-Za-z0-9_.-]+$/) ||
            names[name] ||
            type(args) != "array" || length(args) != 9 ||
            type(args[0]) != "string" || !match(args[0], /(^|\/)ucode$/) || args[1] != "-L" ||
            args[2] != library_path || args[3] != runtime_path ||
            args[4] != "supervisor" || args[5] != name ||
            args[8] != child_pid_dir + "/" + name + ".pid")
            return null;
        for (let arg in args)
            if (type(arg) != "string")
                return null;
        names[name] = true;
    }
    return entries;
}

function owned_process(path, executable, args) {
    let saved = process_identity.read_record(path);
    if (saved == null)
        return null;
    if (!running(saved.pid))
        return { path, pid: saved.pid, ticks: saved.ticks, executable, args, live: false };
    if (saved.ticks == "" || process_identity.matches(path, executable, args, false, true) != saved.pid)
        return null;
    return { path, pid: saved.pid, ticks: saved.ticks, executable, args, live: true };
}

function same_live(item) {
    return running(item.pid) && process_identity.start_ticks(item.pid) == item.ticks;
}

function descendant_children(supervisor, child_executable, child_args, already) {
    let found = [];
    let parent_record = { pid: supervisor.pid, ticks: supervisor.ticks };
    if (process_identity.matches_record(parent_record, "ucode", supervisor.args, false, true) != supervisor.pid)
        return found;
    let stream = fs.popen("find /proc -mindepth 1 -maxdepth 1 -type d", "r");
    if (stream == null)
        return found;
    let path;
    while ((path = stream.read("line")) != null) {
        let pid = replace(trim(path), /^.*\//, "");
        if (!match(pid, /^[1-9][0-9]*$/) || !process_identity.descendant_of(pid, supervisor.pid))
            continue;
        let known = false;
        for (let item in already)
            if (item.pid == pid)
                known = true;
        if (known)
            continue;
        let ticks = process_identity.start_ticks(pid);
        if (ticks == "")
            continue;
        let record = { pid, ticks };
        if (process_identity.matches_record(record, child_executable, child_args, false, true) == pid &&
            process_identity.matches_record(parent_record, "ucode", supervisor.args, false, true) == supervisor.pid)
            push(found, { pid, ticks, executable: child_executable, args: child_args, live: true, record });
    }
    stream.close();
    return found;
}

function signal_owned(item, kind) {
    return item.record != null
        ? process_identity.signal_record(item.record, item.executable, item.args, false, kind)
        : process_identity.signal(item.path, item.executable, item.args, false, kind, true);
}

function stop_owned(pid_dir, child_pid_dir, runtime_path, library_path, child_executable, child_args) {
    let processes = [];
    for (let path in pidfiles(pid_dir)) {
        let name = replace(replace(path, /^.*\//, ""), /\.pid$/, "");
        if (!match(name, /^[A-Za-z0-9_.-]+$/))
            return false;
        let item = owned_process(path, "ucode", [ "ucode", "-L", library_path, runtime_path, "supervisor", name ]);
        if (item == null)
            return false;
        push(processes, item);
    }
    for (let path in pidfiles(child_pid_dir)) {
        let name = replace(replace(path, /^.*\//, ""), /\.pid$/, "");
        if (!match(name, /^[A-Za-z0-9_.-]+$/))
            return false;
        let saved = process_identity.read_record(path);
        if (saved != null && saved.ticks == "" && running(saved.pid))
            process_identity.promote_legacy_child(path, pid_dir + "/" + name + ".pid",
                [ "ucode", "-L", library_path, runtime_path, "supervisor", name ],
                child_executable, child_args);
        let item = owned_process(path, child_executable, child_args);
        if (item == null)
            return false;
        if (item.live) {
            let parent_owned = false;
            for (let parent in processes)
                if (parent.path == pid_dir + "/" + name + ".pid" && parent.live &&
                    process_identity.descendant_of(item.pid, parent.pid))
                    parent_owned = true;
            if (!parent_owned)
                return false;
        }
        push(processes, item);
    }
    for (let parent in processes) {
        if (!parent.live || parent.executable != "ucode")
            continue;
        for (let child in descendant_children(parent, child_executable, child_args, processes))
            push(processes, child);
    }
    for (let item in processes)
        if (item.live && !signal_owned(item, "TERM") && same_live(item))
            return false;
    command_success([ "sleep", "1" ]);
    for (let item in processes) {
        if (item.live && same_live(item) &&
            !signal_owned(item, "KILL") && same_live(item))
            return false;
    }
    command_success([ "sleep", "1" ]);
    for (let item in processes)
        if (item.live && same_live(item))
            return false;
    for (let item in processes)
        if (item.path != null && fs.stat(item.path) != null && !fs.unlink(item.path))
            return false;
    return true;
}

function restore(input_path, pid_dir, child_pid_dir, log_dir, runtime_path, library_path, child_executable, child_args) {
    let entries = valid_entries(input_path, child_pid_dir, runtime_path, library_path);
    if (entries == null || !command_success([ "mkdir", "-p", pid_dir, child_pid_dir, log_dir ]) ||
        !stop_owned(pid_dir, child_pid_dir, runtime_path, library_path, child_executable, child_args))
        return false;
    if (length(entries) == 0)
        return true;
    let launched = [];
    for (let entry in entries) {
        let name = entry.name;
        let args = entry.args;
        let logfile = log_dir + "/" + name + ".log";
        let launch = command_from_args(args) + " >>" + shell_quote(logfile) + " 2>&1 1000>&- & echo $!";
        let stream = fs.popen("sh -c " + shell_quote(launch), "r");
        if (stream == null)
            break;
        let pid = trim(stream.read("line") || "");
        stream.close();
        if (!running(pid))
            break;
        let temporary = log_dir + "/.restore-" + name + ".identity";
        let ticks = process_identity.start_ticks(pid);
        for (let attempt = 0; attempt < 5 && ticks == "" && running(pid); attempt++) {
            command_success([ "sleep", "1" ]);
            ticks = process_identity.start_ticks(pid);
        }
        push(launched, { name, args, pid, ticks, temporary, temporary_written: false });
        if (ticks == "" || fs.writefile(temporary, pid + "\n" + ticks + "\n") == null)
            break;
        launched[length(launched) - 1].temporary_written = true;
        if (!process_identity.record(pid_dir + "/" + name + ".pid", pid))
            break;
        command_success([ "sleep", "1" ]);
        let child_file = child_pid_dir + "/" + name + ".pid";
        let child = process_identity.read_record(child_file);
        if (child != null && child.ticks == "")
            process_identity.promote_legacy_child(child_file, temporary, args, child_executable, child_args);
        child = process_identity.read_record(child_file);
        if (!running(pid) || child == null || child.ticks == "" ||
            process_identity.matches(child_file, child_executable, child_args, false, true) != child.pid)
            break;
        if (length(launched) == length(entries)) {
            for (let item in launched)
                if (item.temporary_written)
                    fs.unlink(item.temporary);
            return true;
        }
    }
    // Allow a just-launched supervisor to expose its child before ancestry is lost.
    command_success([ "sleep", "1" ]);
    let cleanup = [];
    for (let item in launched) {
        let parent_record = { pid: item.pid, ticks: item.ticks };
        push(cleanup, { pid: item.pid, ticks: item.ticks,
            executable: "ucode", args: item.args, live: true, record: parent_record,
            path: item.temporary, temporary: item.temporary_written });
        let child_file = child_pid_dir + "/" + item.name + ".pid";
        let child = process_identity.read_record(child_file);
        if (item.temporary_written && child != null && child.ticks == "")
            process_identity.promote_legacy_child(child_file, item.temporary, item.args,
                child_executable, child_args);
        child = process_identity.read_record(child_file);
        if (child != null && child.ticks != "" &&
            process_identity.matches_record(parent_record, "ucode", item.args, false, true) == item.pid &&
            process_identity.descendant_of(child.pid, item.pid) &&
            process_identity.matches_record(child, child_executable, child_args, false, true) == child.pid) {
            push(cleanup, { path: child_file, pid: child.pid, ticks: child.ticks,
                executable: child_executable, args: child_args, live: true });
        }
        for (let orphan in descendant_children(item, child_executable, child_args, cleanup))
            push(cleanup, orphan);
    }
    for (let item in cleanup)
        signal_owned(item, "TERM");
    command_success([ "sleep", "1" ]);
    for (let item in cleanup)
        if (same_live(item))
            signal_owned(item, "KILL");
    command_success([ "sleep", "1" ]);
    for (let item in cleanup)
        if (!same_live(item) && item.temporary && item.path != null)
            fs.unlink(item.path);
    for (let item in launched) {
        if (!running(item.pid) || process_identity.start_ticks(item.pid) != item.ticks) {
            fs.unlink(pid_dir + "/" + item.name + ".pid");
            let child_file = child_pid_dir + "/" + item.name + ".pid";
            let child = process_identity.read_record(child_file);
            if (child == null || !running(child.pid) || process_identity.start_ticks(child.pid) != child.ticks)
                fs.unlink(child_file);
        }
    }
    return false;
}

return { snapshot, restore, valid_entries, stop_owned };
