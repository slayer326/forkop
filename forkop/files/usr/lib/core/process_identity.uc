let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash < 0 ? path : substr(path, slash + 1);
}

function start_ticks(pid) {
    pid = as_string(pid);
    if (match(pid, /^[1-9][0-9]*$/) == null)
        return "";
    let stat = fs.readfile("/proc/" + pid + "/stat");
    if (stat == null)
        return "";
    let marker = rindex(stat, ") ");
    if (marker < 0)
        return "";
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    if (length(fields) < 20 || match(fields[19], /^[0-9]+$/) == null)
        return "";
    return fields[19];
}

function parent_pid(pid) {
    let stat = fs.readfile("/proc/" + as_string(pid) + "/stat");
    if (stat == null)
        return "";
    let marker = rindex(stat, ") ");
    if (marker < 0)
        return "";
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    return length(fields) > 1 && match(fields[1], /^[1-9][0-9]*$/) != null ? fields[1] : "";
}

function descendant_of(pid, ancestor) {
    pid = as_string(pid);
    ancestor = as_string(ancestor);
    for (let depth = 0; depth < 5; depth++) {
        pid = parent_pid(pid);
        if (pid == "")
            return false;
        if (pid == ancestor)
            return true;
    }
    return false;
}

function record(path, pid) {
    path = as_string(path);
    pid = as_string(pid);
    if (match(pid, /^[1-9][0-9]*$/) == null)
        return false;
    let ticks = "";
    for (let attempt = 0; attempt < 5 && ticks == ""; attempt++) {
        ticks = start_ticks(pid);
        if (ticks == "")
            system("sleep 1");
    }
    if (ticks == "")
        return false;
    let temporary = path + "." + pid + ".tmp";
    if (fs.writefile(temporary, pid + "\n" + ticks + "\n") == null)
        return false;
    if (!fs.rename(temporary, path)) {
        fs.unlink(temporary);
        return false;
    }
    return true;
}

function read_record(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;
    let lines = split(trim(data), "\n");
    let pid = trim(lines[0] || "");
    let ticks = trim(lines[1] || "");
    if (match(pid, /^[1-9][0-9]*$/) == null ||
        (length(lines) > 1 && match(ticks, /^[0-9]+$/) == null) ||
        length(lines) > 2)
        return null;
    return { pid, ticks };
}

function matches_record(saved, expected_executable, expected_argv, exact, require_ticks) {
    if (type(saved) != "object" || type(saved.pid) != "string" ||
        match(saved.pid, /^[1-9][0-9]*$/) == null || type(saved.ticks) != "string" ||
        (saved.ticks != "" && match(saved.ticks, /^[0-9]+$/) == null) ||
        (require_ticks && saved.ticks == ""))
        return "";
    let current_ticks = start_ticks(saved.pid);
    if (current_ticks == "" || (saved.ticks != "" && current_ticks != saved.ticks))
        return "";
    let exe = fs.readlink("/proc/" + saved.pid + "/exe");
    if (exe == null)
        return "";
    let exe_name = basename(exe);
    if (saved.ticks != "")
        exe_name = replace(exe_name, / \(deleted\)$/, "");
    if (exe_name != basename(expected_executable))
        return "";
    let raw = fs.readfile("/proc/" + saved.pid + "/cmdline");
    if (raw == null)
        return "";
    let argv = split(raw, "\0");
    if (length(argv) > 0 && argv[length(argv) - 1] == "")
        pop(argv);
    if (length(argv) < length(expected_argv) || (exact && length(argv) != length(expected_argv)))
        return "";
    for (let i = 0; i < length(expected_argv); i++) {
        if (expected_argv[i] == null)
            continue;
        if (i == 0) {
            if (basename(argv[i]) != basename(expected_argv[i]))
                return "";
        }
        else if (argv[i] != expected_argv[i])
            return "";
    }
    // Recheck after reading exe/cmdline; a reused PID must not inherit the
    // first observation of a different process.
    return start_ticks(saved.pid) == current_ticks ? saved.pid : "";
}

function matches(path, expected_executable, expected_argv, exact, require_ticks) {
    return matches_record(read_record(path), expected_executable, expected_argv, exact, require_ticks);
}

function signal_saved(saved, expected_executable, expected_argv, exact, kind, require_ticks) {
    let pid = matches_record(saved, expected_executable, expected_argv, exact, require_ticks);
    if (pid == "")
        return false;
    return system("kill -" + (kind == "KILL" ? "9" : "15") + " " + pid + " >/dev/null 2>&1") == 0;
}

function signal_record(saved, expected_executable, expected_argv, exact, kind) {
    return signal_saved(saved, expected_executable, expected_argv, exact, kind, true);
}

function signal(path, expected_executable, expected_argv, exact, kind, require_saved_ticks) {
    return signal_saved(read_record(path), expected_executable, expected_argv, exact, kind,
        kind == "KILL" || require_saved_ticks);
}

function promote_legacy_child(child_path, supervisor_path, supervisor_argv, child_executable, child_argv) {
    let child = read_record(child_path);
    if (child == null)
        return false;
    if (child.ticks != "")
        return true;
    let supervisor_pid = matches(supervisor_path, "ucode", supervisor_argv, false, false);
    let child_pid = matches(child_path, child_executable, child_argv, false, false);
    if (supervisor_pid == "" || child_pid == "" || !descendant_of(child_pid, supervisor_pid))
        return false;
    return record(child_path, child_pid);
}

return { start_ticks, descendant_of, record, read_record, matches, matches_record, signal, signal_record, promote_legacy_child };
