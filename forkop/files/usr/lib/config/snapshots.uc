#!/usr/bin/env ucode

let fs = require("fs");
let identity = require("core.process_identity");
let runtime_lock = require("core.runtime_lock");
let list_worker = require("core.list_worker");

const CONFIG = getenv("FORKOP_CONFIG_FILE") || "/etc/config/forkop";
const ROOT = getenv("FORKOP_SNAPSHOT_DIR") || "/etc/forkop/config-snapshots";
const HASH_DIR = getenv("FORKOP_SNAPSHOT_HASH_DIR") || "/var/run/forkop/snapshot-hash";
const LOCK = getenv("FORKOP_SNAPSHOT_LOCK_DIR") || "/var/run/forkop/config-snapshot.lock";
const LKG = ROOT + "/last-known-working";
const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const RELOAD = getenv("FORKOP_RELOAD_COMMAND") || "/etc/init.d/forkop";
const MAX_CONFIG = 2 * 1024 * 1024;
const PENDING_RELOAD = getenv("FORKOP_PENDING_RELOAD_FILE") || "/var/run/forkop/reload.pending";
const RELOAD_LOCK = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
// An explicit stop (service/initd.uc, service/lifecycle.uc): until an
// explicit start no reload brings the runtime back (D-15, UC-056).
const STOP_REQUESTED = getenv("FORKOP_STOP_REQUESTED_FILE") ||
    (getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop") + "/stop.requested";
// The record of the last DPI autotune apply (autotune/apply.uc) and the
// phases in which that apply is finished.
const AUTOTUNE_APPLY_STATE = getenv("FORKOP_AUTOTUNE_APPLY_STATE") || "/etc/forkop/autotune-apply.json";
const AUTOTUNE_TERMINAL_PHASES = [ "applied", "rolled_back", "failed", "stale", "no_change_required", "needs_attention" ];
// The save directory of `uci set` without a commit; libuci reads every
// cursor through it (autotune/apply.uc and manager.uc check it too, with the
// override FORKOP_AUTOTUNE_UCI_SAVEDIR). Tests that restore set it.
const UCI_SAVEDIR = getenv("FORKOP_UCI_SAVEDIR") || "/tmp/.uci";
const RETENTION = 10;
const GUARD_SETTLE_SECONDS = int(getenv("FORKOP_RUNTIME_GUARD_SETTLE_SECONDS") || "30");

function value(v) { return v == null ? "" : "" + v; }
function quote(v) { return "'" + replace(value(v), /'/g, "'\\''") + "'"; }
function cmd(args) {
    let parts = [];
    for (let arg in args) push(parts, quote(arg));
    return join(" ", parts);
}
function capture(args) {
    let pipe = fs.popen(cmd(args) + " 2>/dev/null", "r");
    if (!pipe) return "";
    let result = pipe.read("all");
    return pipe.close() == 0 && result != null ? result : "";
}
function success(args) { return system(cmd(args) + " >/dev/null 2>&1") == 0; }
function valid_id(id) { return match(value(id), /^[a-z0-9_-]{1,64}$/) != null; }
function valid_hash(v) { return match(value(v), /^[0-9a-f]{64}$/) != null; }
function snapshot_path(id) { return ROOT + "/" + id + ".json"; }
function read_config() {
    let data = fs.readfile(CONFIG);
    return data != null && length(data) <= MAX_CONFIG ? data : null;
}
function sha(data) {
    let parent = fs.dirname(HASH_DIR);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return "";
    if (fs.stat(HASH_DIR) == null && !fs.mkdir(HASH_DIR, 0700)) return "";
    if (!fs.chmod(HASH_DIR, 0700)) return "";
    let tmp = HASH_DIR + "/.hash." + sprintf("%d.%d", clock()[0], clock()[1]);
    if (fs.writefile(tmp, data) == null) return "";
    let output = capture([ "sha256sum", tmp ]);
    fs.unlink(tmp);
    let hash = split(output, " ")[0];
    return length(hash) == 64 && match(hash, /^[0-9a-f]+$/) != null ? hash : "";
}
function atomic(path, data) {
    let tmp = path + "." + sprintf("%d.%d", clock()[0], clock()[1]) + ".tmp";
    if (fs.writefile(tmp, data) == null || !fs.chmod(tmp, 0600) || !fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }
    return true;
}
function ensure_root() {
    let parent = fs.dirname(ROOT);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    if (fs.stat(ROOT) == null && !fs.mkdir(ROOT, 0700)) return false;
    return fs.chmod(ROOT, 0700);
}
// The lock is a runtime directory holding one "owner.<pid>.<start ticks>"
// record. The name is unique per process lifetime, so unlinking a stale or
// own record by name can never remove the record of a lock that replaced it.
let lock_record = null;
let lock_busy = false;   // set when a live snapshot operation owns the lock
function owner_pid() {
    let pid = value(fs.readlink("/proc/self"));
    return match(pid, /^[1-9][0-9]*$/) != null ? pid : "";
}
function active_entry(name) {
    let parsed = match(value(name), /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
    if (parsed == null) return false;
    for (let operation in [ "create", "delete", "restore", "apply", "confirm-working" ])
        if (identity.matches_record({ pid: parsed[1], ticks: parsed[2] }, "ucode",
            [ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/snapshots.uc", operation ], false, true) != "")
            return true;
    return false;
}
function remove_lock_dir(dir) {
    for (let name in fs.lsdir(dir) || []) fs.unlink(dir + "/" + name);
    return fs.rmdir(dir);
}
function acquire() {
    if (!ensure_root()) return false;
    let parent = fs.dirname(LOCK);
    if (fs.stat(parent) == null && !fs.mkdir(parent, 0700)) return false;
    let pid = owner_pid(), ticks = identity.start_ticks(pid);
    if (ticks == "") return false;
    let name = "owner." + pid + "." + ticks;
    // The record is complete before the lock becomes visible, so no observer
    // can mistake a lock that is still being initialised for a stale one.
    let pending = LOCK + ".new." + pid + "." + ticks;
    remove_lock_dir(pending);
    if (!fs.mkdir(pending, 0700) || !identity.record(pending + "/" + name, pid) || !active_entry(name)) {
        remove_lock_dir(pending);
        return false;
    }
    for (let attempt = 0; attempt < 3; attempt++) {
        // rename() refuses a populated lock; an empty one was already released.
        if (fs.rename(pending, LOCK)) {
            lock_record = LOCK + "/" + name;
            return true;
        }
        let stat = fs.lstat(LOCK);
        let entries = stat != null && stat.type == "directory" ? fs.lsdir(LOCK) : null;
        if (entries == null) {
            // Absent, or not a lock directory (never follow a symlink here).
            fs.unlink(LOCK);
            continue;
        }
        let busy = false;
        for (let entry in entries) if (active_entry(entry)) busy = true;
        if (busy) { lock_busy = true; break; }
        for (let entry in entries)
            if (!fs.unlink(LOCK + "/" + entry)) fs.rmdir(LOCK + "/" + entry);
    }
    remove_lock_dir(pending);
    return false;
}
function release() {
    if (lock_record == null) return;
    fs.unlink(lock_record);
    fs.rmdir(LOCK);
    lock_record = null;
}
function read_snapshot(id, verify) {
    if (!valid_id(id)) return null;
    let data = fs.readfile(snapshot_path(id));
    if (data == null || length(data) > MAX_CONFIG + 8192) return null;
    try {
        let parsed = json(data);
        return type(parsed) == "object" && parsed.id == id &&
            type(parsed.content) == "string" && length(parsed.content) <= MAX_CONFIG &&
            length(value(parsed.config_hash)) == 64 && match(value(parsed.config_hash), /^[0-9a-f]+$/) != null &&
            (!verify || sha(parsed.content) == parsed.config_hash) ? parsed : null;
    }
    catch (e) { return null; }
}
function metadata(snapshot) {
    return { id: snapshot.id, created_at: snapshot.created_at,
        kind: index([ "manual", "automatic" ], snapshot.kind) >= 0 ? snapshot.kind : "unknown",
        reason: index([ "manual", "before-reload", "pre-restore", "last-known-working", "before-autotune", "concurrent-change" ], snapshot.reason) >= 0 ? snapshot.reason : "unknown",
        config_hash: snapshot.config_hash,
        forkop_version: match(value(snapshot.forkop_version), /^[A-Za-z0-9._-]{1,64}$/) != null ? snapshot.forkop_version : "unknown" };
}
// Hash of the configuration the last-known-working snapshot holds.
function lkg_hash() {
    let item = read_snapshot(trim(value(fs.readfile(LKG))), false);
    return item != null ? item.config_hash : "";
}
// A completed autotune apply still offers an explicit rollback to its
// pre-apply snapshot. Keep it until that record is replaced or rolled back.
// An unreadable record may name a recovery point we cannot identify: refuse
// pruning and deletion rather than silently losing it.
function autotune_snapshot_protection() {
    if (fs.stat(AUTOTUNE_APPLY_STATE) == null) return { all: false, id: "" };
    let record = null;
    try { record = json(value(fs.readfile(AUTOTUNE_APPLY_STATE))); } catch (e) { record = null; }
    if (type(record) != "object") return { all: true, id: "" };
    // The apply records its pre-snapshot only after the snapshot transaction
    // returns. During that narrow window, the record cannot identify it yet.
    if (record.phase == "applying" && record.reload == null) return { all: true, id: "" };
    if (record.reload == null || record.phase == "rolled_back") return { all: false, id: "" };
    let id = value(record.pre_snapshot);
    return valid_id(id) ? { all: false, id } : { all: true, id: "" };
}
function recovery_protects(protection, id) { return protection.all || protection.id == id; }
function list_snapshots() {
    let result = [];
    let working = trim(value(fs.readfile(LKG)));
    let protection = autotune_snapshot_protection();
    for (let file in fs.lsdir(ROOT) || []) {
        let id = replace(file, /\.json$/, "");
        if (file != id + ".json" || !valid_id(id)) continue;
        let item = read_snapshot(id, false);
        if (item == null) continue;
        let entry = metadata(item);
        entry.is_lkg = id == working;
        entry.is_protected = recovery_protects(protection, id);
        push(result, entry);
    }
    result = sort(result, function(a, b) { return a.created_at - b.created_at; });
    return result;
}
// Oldest automatic snapshots go first; manual ones, LKG and the ids the
// running operation still needs (keep) are never removed.
function trim_retention(keep) {
    let all = list_snapshots();
    let working = trim(value(fs.readfile(LKG)));
    while (length(all) >= RETENTION) {
        let candidate = null;
        for (let item in all)
            if (item.kind != "manual" && item.id != working && !item.is_protected && index(keep || [], item.id) < 0) { candidate = item; break; }
        if (candidate == null) return false;
        fs.unlink(snapshot_path(candidate.id));
        all = list_snapshots();
    }
    return true;
}
// Snapshots that can still be created without touching LKG, manual ones or keep.
function headroom(keep) {
    let all = list_snapshots();
    let working = trim(value(fs.readfile(LKG)));
    let free = RETENTION - length(all);
    for (let item in all)
        if (item.kind != "manual" && item.id != working && !item.is_protected && index(keep || [], item.id) < 0) free++;
    return free;
}
// dedupe: true returns any snapshot that already holds the configuration, a
// reason only one of that reason.
function create(kind, reason, dedupe, keep) {
    let content = read_config();
    if (content == null) return { status: "failed", reason: "config_unavailable" };
    let hash = sha(content);
    if (hash == "") return { status: "failed", reason: "hash_unavailable" };
    if (dedupe)
        for (let item in list_snapshots())
            if (item.config_hash == hash && (dedupe === true || item.reason == dedupe)) return { status: "existing", snapshot: item };
    if (!trim_retention(keep)) return { status: "failed", reason: "retention_full" };
    let id = sprintf("%d_%d", clock()[0], clock()[1]);
    let version = trim(capture([ BIN, "show_version" ]));
    let snapshot = { id, created_at: int(clock()[0]), kind, reason,
        config_hash: hash, forkop_version: match(version, /^[A-Za-z0-9._-]{1,64}$/) != null ? version : "unknown", content };
    if (fs.stat(snapshot_path(id)) != null ||
        !atomic(snapshot_path(id), sprintf("%J\n", snapshot)))
        return { status: "failed", reason: "write_failed" };
    return { status: "created", snapshot: metadata(snapshot) };
}
function safe_value(option, raw) {
    if (index([ "enabled", "action", "dns_type", "dns_strategy", "disable_quic" ], option) >= 0 &&
        match(raw, /^[A-Za-z0-9_-]{1,32}$/) != null) return raw;
    if (index([ "dns_server", "bootstrap_dns_server" ], option) >= 0 &&
        match(raw, /^[0-9A-Fa-f:.]{1,45}$/) != null) return raw;
    return "***";
}
// Parses a UCI value made of quoted/unquoted segments ('it'\''s', "a\"b").
// A quoted value may span lines; null means the quote is still open.
function uci_value(text) {
    let result = "", quote = null;
    for (let i = 0; i < length(text); i++) {
        let c = substr(text, i, 1);
        if (quote == "'") {
            if (c == "'") quote = null; else result += c;
        }
        else if (quote == "\"") {
            if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
            else if (c == "\"") quote = null;
            else result += c;
        }
        else if (c == "'" || c == "\"") quote = c;
        else if (c == "\\" && i + 1 < length(text)) result += substr(text, ++i, 1);
        else if (c == " " || c == "\t") break;
        else result += c;
    }
    return quote == null ? result : null;
}
// Options by "<section>.<option>". Every `config <type> ['<name>']` line
// starts a section. One without a name (libuci writes anonymous sections so)
// is keyed as libuci addresses it, @<type>[<n>], n counting every section of
// that type in file order (a named section that appears again is the same
// section): its options never merge into the named section before it
// (UC-018). A header this reader cannot parse ends the section before it, so
// what follows is attributed to no other section. The \r of a CRLF line end is
// a blank to libuci, so it is no part of a line here. An option followed by a
// list of the same name is one list, the option's value first, as libuci
// loads it.
function options(content) {
    let result = {};
    let section = null, count = {}, named = {};
    let lines = map(split(content, "\n"), (line) => replace(line, /\r$/, ""));
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (match(line, /^[ \t]*config([ \t]|$)/) != null) {
            let start = match(line, /^[ \t]*config[ \t]+['"]?([^ \t'"#;\\]+)['"]?([ \t]+['"]?([A-Za-z0-9_-]*)['"]?)?[ \t]*(#.*)?$/);
            section = null;
            if (start != null) {
                let type = start[1], name = start[3], n = count[type] ?? 0;
                if (name == null || name == "") { section = sprintf("@%s[%d]", type, n); count[type] = n + 1; }
                else {
                    section = name;
                    if (!named[name]) { named[name] = true; count[type] = n + 1; }
                }
            }
            continue;
        }
        let opt = match(line, /^[ \t]*(option|list)[ \t]+([A-Za-z0-9_-]+)[ \t]+(.+)$/);
        if (section == null || opt == null) continue;
        // Continuation lines of a quoted multi-line value belong to this option.
        let text = trim(opt[3]), raw = uci_value(text);
        while (raw == null && i + 1 < length(lines)) {
            text += "\n" + lines[++i];
            raw = uci_value(text);
        }
        if (raw == null) raw = text;
        let key = section + "." + opt[2];
        if (opt[1] == "list") {
            if (result[key] == null)
                result[key] = { kind: "list", values: [] };
            else if (result[key].kind != "list")
                result[key] = { kind: "list", values: [ result[key].value ] };
            push(result[key].values, raw);
        }
        // An option statement without a value sets nothing, as libuci loads
        // it (see uci_sections): an earlier value stays, alone it is not set.
        else if (raw != "")
            result[key] = { kind: "option", value: raw };
    }
    return result;
}
function safe_values(option, values) {
    let result = [];
    for (let raw in values) push(result, safe_value(option, raw));
    return result;
}
// A side without the option is null, "not set"; '***' stands only for a
// value that exists and is hidden (D-2, UC-063). Absence tells nothing of a
// value: the option name is shown anyway. An option side stays scalar so
// option <-> list changes remain visible.
function diff_side(option, entry) {
    if (entry == null) return null;
    return entry.kind == "list" ? safe_values(option, entry.values) : safe_value(option, entry.value);
}
// At most DIFF_ROWS changes are listed. A longer diff ends with a marker in
// place of the rest, { truncated: true, total }, total counting every changed
// option, so no reader takes the list for the whole change (UC-062). The
// array form stays for its readers; the marker holds a count, no value.
const DIFF_ROWS = 100;
function diff(before, after) {
    let old = options(before), current = options(after), result = [], total = 0;
    let all = {};
    for (let key in keys(old)) all[key] = true;
    for (let key in keys(current)) all[key] = true;
    for (let key in keys(all)) {
        let a = old[key], b = current[key];
        // An option name has no dot; an anonymous section's type may.
        let dot = rindex(key, "."), option = substr(key, dot + 1);
        let row = { section: substr(key, 0, dot), option };
        if ((a != null && a.kind == "list") || (b != null && b.kind == "list")) {
            if (a != null && b != null && a.kind == b.kind &&
                sprintf("%J", a.values) == sprintf("%J", b.values)) continue;
            row.kind = "list";
        }
        else if (a != null && b != null && a.value == b.value) continue;
        if (++total > DIFF_ROWS) continue;
        row.before = diff_side(option, a);
        row.after = diff_side(option, b);
        push(result, row);
    }
    if (total > DIFF_ROWS) push(result, { truncated: true, total });
    return result;
}
// Install uses ensure semantics: after needs_attention the guard from the
// failed restore is still active and must protect the recovery restore too.
// It is removed only after a reload proved a coherent runtime.
function restore_guard(remove) {
    return success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/nft/apply.uc",
        remove ? "remove-dpi-transition-guard" : "ensure-dpi-transition-guard", "ForkopConfigRestore" ]);
}
// "absent", "valid" or "invalid"; empty when the state is unknown.
function restore_guard_state() {
    return trim(capture([ "ucode", "-L", LIB_DIR, LIB_DIR + "/nft/apply.uc",
        "dpi-transition-guard-state", "ForkopConfigRestore" ]));
}
// A lifecycle action (subscription update, WAN-up reload, start, a
// pending-reload drain) owns the reload lock, and a running list update gets
// every reload queued for it, with or without the lock: a reload requested
// now would only be queued behind either. A queued reload without a live
// owner is no such action: the next reload takes the free lock and its
// finish drains that request. A restore relies on this, so recovery stays
// possible while the current configuration cannot reload and keeps failing
// to drain the queue. The lock and its owner record: core/runtime_lock.uc;
// the list worker: core/list_worker.uc.
function service_action() {
    return runtime_lock.busy(RELOAD_LOCK) || list_worker.running(LIB_DIR) ? "service_action_in_progress" : null;
}
// A fail-closed guard that a failed lifecycle transition kept: the DPI guard
// table of a failed DPI rollback or the transition guard chain of a failed
// sing-box rollback (service/lifecycle.uc runtime_guard_kept). It drops the
// traffic it guards until a restart removes it, and the lifecycle refuses
// every reload over it: while it is there no reload proves a coherent
// runtime, whatever its exit status (UC-019).
function runtime_guard_kept() {
    let table = getenv("NFT_TABLE_NAME") || "ForkopTable";
    return success([ "nft", "list", "table", "inet", table + "DpiGuard" ]) ||
        success([ "nft", "list", "chain", "inet", table, "forkop_transition_guard" ]);
}
// The same, read after init.d released reload.lock. A lifecycle action that
// holds the lock by then (a WAN-up or hotplug reload that took it next, the
// holder a queued reload waited for) installs the same guards for its own
// transition and removes them when it ends: a guard seen while one runs is
// kept only if it outlasts that action. Wait for it, bounded; a guard still
// there under a busy lock after the bound counts as kept (fail closed).
function runtime_guard_settled() {
    for (let waited = 0; runtime_guard_kept(); waited++) {
        if (service_action() == null || waited >= GUARD_SETTLE_SECONDS) return true;
        success([ "sleep", "1" ]);
    }
    return false;
}
// Changes to forkop staged with uci but not committed. The validator, the
// generator and the lifecycle read the configuration through them, so a
// restore would validate and load the snapshot plus these changes while LKG
// names the pure snapshot (UC-068). LuCI keeps its unsaved changes per rpcd
// session, outside this directory: no reload reads them (the History page
// asks for those to be saved or reverted first).
function staged_changes() {
    let st = fs.stat(UCI_SAVEDIR + "/forkop");
    return st != null && st.size > 0;
}
// A reload that was only queued (another lifecycle action took the reload
// lock after the check above) exits 0 without touching the runtime. init.d
// acknowledges it with a "queued" line for this caller's reason; a changed
// pending-reload marker (unique per request) is the second witness. A request
// queued before the call is drained by a reload that ran (the marker is
// gone); a drain that failed rewrites it and so never counts as ran.
function pending_stamp() {
    let st = fs.stat(PENDING_RELOAD);
    return st == null ? null : sprintf("%d:%d:%s", st.mtime, st.size, value(fs.readfile(PENDING_RELOAD)));
}
// "ran", "queued", "stopped" or "failed". "stopped": an explicit stop, or
// no explicit start since boot, holds the runtime down, so the reload was
// skipped (or the runtime it reloaded is down again) and nothing runs the
// configuration; init.d says so for this caller's reason (D-15, UC-056).
function reload(reason) {
    let before = pending_stamp();
    let pipe = fs.popen(cmd([ RELOAD, "reload", reason ]) + " 2>/dev/null", "r");
    if (!pipe) return "failed";
    let output = value(pipe.read("all"));
    if (pipe.close() != 0) return "failed";
    for (let line in split(output, "\n")) {
        if (trim(line) == "queued") return "queued";
        if (trim(line) == "stopped") return "stopped";
    }
    let after = pending_stamp();
    return after != null && after != before ? "queued" : "ran";
}
// The user configuration, without the lifecycle's own shutdown_correctly
// bookkeeping, hashed as autotune/apply.uc fingerprints it.
function user_fingerprint(content) {
    let lines = [];
    for (let line in split(content, "\n"))
        if (match(line, /^[ \t]*option[ \t]+shutdown_correctly([ \t]|$)/) == null) push(lines, line);
    return sha(join("\n", lines));
}
// Blanks between words: space, \t, \v, \f, \r.
function uci_space(c) { return c == 32 || c == 9 || c == 11 || c == 12 || c == 13; }
// The statements of a configuration file as libuci's parser splits them
// (file.c): words with quotes and escapes resolved, comments dropped; a word
// is raw when it had neither. null for an open quote or for syntax this
// reader does not follow (';', a backslash line continuation).
function uci_statements(text) {
    let result = [], words = [], word = null;
    let end_word = () => { if (word != null) push(words, word); word = null; };
    let lines = split(text, "\n");
    for (let l = 0; l < length(lines); l++) {
        let line = lines[l], i = 0, n = length(line);
        // A backslash at the end of a line (or of the file) continues it.
        let continuation = () => i >= n || (i == n - 1 && substr(line, i, 1) == "\r");
        while (i < n) {
            let c = substr(line, i, 1);
            if (uci_space(ord(c))) { end_word(); i++; continue; }
            if (c == "#") break;
            if (c == ";") return null;
            if (word == null) word = { text: "", raw: true };
            if (c == "'" || c == "\"") {
                // A quoted run may span lines; inside double quotes a
                // backslash takes the next character.
                word.raw = false;
                i++;
                while (true) {
                    let rest = substr(line, i), close = index(rest, c);
                    let escape = c == "\"" ? index(rest, "\\") : -1;
                    if (escape >= 0 && (close < 0 || escape < close)) {
                        word.text += substr(rest, 0, escape);
                        i += escape + 1;
                        if (continuation()) return null;
                        word.text += substr(line, i++, 1);
                    }
                    else if (close >= 0) { word.text += substr(rest, 0, close); i += close + 1; break; }
                    else {
                        word.text += rest + "\n";
                        if (++l >= length(lines)) return null;
                        line = lines[l]; i = 0; n = length(line);
                    }
                }
                continue;
            }
            if (c == "\\") { word.raw = false; i++; if (continuation()) return null; }
            let start = i++;
            while (i < n && !uci_space(ord(line, i)) && index("#;'\"\\", substr(line, i, 1)) < 0) i++;
            word.text += substr(line, start, i - start);
        }
        end_word();
        if (length(words)) push(result, words);
        words = [];
    }
    return result;
}
// The sections of a configuration as libuci loads it: a named section that
// appears again is merged into the first, an option keeps its last value,
// list values stay in order. An option statement without a value changes
// nothing (libuci's uci_set of an empty value on load): an earlier value
// stays, and alone it creates no option. null when libuci would not load it
// the same way (see uci_statements) or not at all.
function uci_sections(text) {
    let statements = uci_statements(text);
    if (statements == null) return null;
    let sections = [], current = null;
    let find = (list, name) => { for (let x in list) if (x.name === name) return x; return null; };
    for (let w in statements) {
        let keyword = w[0].raw ? w[0].text : "", args = length(w) - 1;
        if (keyword == "package" || keyword == "p") {
            if (args != 1) return null;
        }
        else if (keyword == "config" || keyword == "c") {
            if (args < 1 || args > 2 || w[1].text == "") return null;
            let name = args == 2 ? w[2].text : "";
            current = name == "" ? null : find(sections, name);
            if (current != null && current.type != w[1].text) return null;
            if (current == null) push(sections, current = { name: name == "" ? null : name, type: w[1].text, options: [] });
        }
        else if (keyword == "option" || keyword == "o" || keyword == "list" || keyword == "l") {
            if (current == null || args < 1 || args > 2 || w[1].text == "") return null;
            let name = w[1].text, value = args == 2 ? w[2].text : "", option = find(current.options, name);
            if (substr(keyword, 0, 1) == "o") {
                if (value == "") continue;
                if (option != null) { option.list = false; option.value = value; }
                else push(current.options, { name, list: false, value });
            }
            else if (option == null) push(current.options, { name, list: true, value: [ value ] });
            else if (!option.list) { option.list = true; option.value = [ option.value, value ]; }
            else push(option.value, value);
        }
        else return null;
    }
    return sections;
}
// The user configuration as libuci loads it (without shutdown_correctly), or
// null (see uci_sections).
function uci_canonical(text) {
    let sections = uci_sections(text);
    if (sections == null) return null;
    for (let s in sections) s.options = filter(s.options, (o) => o.name != "shutdown_correctly");
    return sprintf("%J", sections);
}
// Whether the configuration file still holds `content`: byte for byte, or as
// libuci loads both. A start or restart inside the reload commits
// shutdown_correctly through libuci, which rewrites the whole file in its own
// form (quotes, indentation, blank lines; comments go): that is no edit, nor
// is a change of comments or formatting alone, which loads the same
// configuration (and the next uci commit drops it anyway). No hash is
// involved, so a failing hash tool cannot make two files look equal; a file
// this reader cannot load holds nothing (fail closed). Comparing the loaded
// forms takes a while for a big file (seconds on a router): the file is read
// again afterwards, and an edit committed meanwhile is one as well, so the
// caller writes over nothing it has not compared.
function config_holds(content) {
    let current = read_config();
    if (current == null) return false;
    if (current == content) return true;
    let loaded = uci_canonical(current);
    return loaded != null && loaded == uci_canonical(content) && read_config() === current;
}
// A configuration that someone else wrote while a transaction owned the file
// (a LuCI Save & Apply, an autotune policy change, a URLTest override: UCI
// commits never take the snapshot lock). It stays in place and is saved as an
// automatic snapshot (dedupe: once), so a later restore cannot discard it
// either (UC-023, UC-017). Another kind of snapshot that happens to hold the
// same configuration does not count: the id returned is always a "Concurrent
// edit" one, as the page names it, and not, say, a pre-restore snapshot next
// in line for retention. The id, or null when no snapshot could be written
// (retention full of manual snapshots): the edit then lives in the file only.
function save_concurrent_edit(keep) {
    let saved = create("automatic", "concurrent-change", "concurrent-change", keep);
    return saved.snapshot != null ? saved.snapshot.id : null;
}
// Replace the configuration with `content` under the restore guard, validate
// and reload; on failure put `before` back and reload again. The guard also
// keeps the reload from confirming a last-known-working snapshot, so LKG is
// only ever moved by the caller. on_success runs after the guard is released.
// Only a reload that ran counts: after a queued one the configuration is put
// back, and when the rollback reload is queued too nothing proves a coherent
// runtime, so the guard stays and LKG is not touched.
// apply_mode (autotune apply): the caller proved no guard was active and the
// snapshot lock keeps restores out, so the guard is this call's own.
// A configuration that is put back after the target failed reloaded
// coherently, but that proves no more than it did before: last-known-working
// moves to it (pre) only when it already was the last-known-working one. It
// may be an unconfirmed edit, or an autotune candidate that has just failed
// its production verification (UC-059).
// A reload that an explicit stop, or the lack of an explicit start since
// boot, skipped (D-15, UC-056) proves nothing and starts nothing. on_stopped
// (a restore) keeps the validated configuration for the next explicit start;
// otherwise the configuration is put back. LKG is not moved either way. The
// guard goes, also one inherited from an earlier needs_attention: no runtime
// runs that it could protect (the stop took down the one it protected), and
// only a start, which builds the runtime from the configuration, brings one
// up; kept, it would outlive that start with no reload left to remove it.
// An edit committed by someone else while the transaction owns the file is
// never overwritten: one that lands before the write refuses the transaction;
// one that lands during the target reload (or validation) keeps the file as it
// is instead of putting `before` back, saves it as a snapshot (keep: the ids
// that snapshot may not push out) and ends needs_attention with the guard
// active, since no reload proved a coherent runtime; when a stop skipped the
// reload, the guard goes as described above (UC-023). After a reload that
// ran, a restore does not know whether it loaded the snapshot or the edit:
// the edit is saved the same way, the guard goes (the runtime is coherent)
// and LKG does not move (on_success does not run). An apply's caller checks
// the file itself before it confirms anything (autotune/apply.uc).
// A reload proves nothing while a failed lifecycle transition keeps its
// fail-closed guard (runtime_guard_settled): the transaction ends
// needs_attention runtime_guard_active with the guard active and LKG where
// it was; after a failed target `before` is put back without a rollback
// reload, which the lifecycle would refuse until a restart (UC-019).
function guarded_replace(before, content, pre, on_success, reason, apply_mode, on_stopped, keep) {
    // A guard left by an earlier needs_attention protects a runtime no reload
    // has proved yet: only this call's own guard may go without a reload.
    let inherited = !apply_mode && restore_guard_state() != "absent";
    if (!restore_guard(false)) return { status: "failed", reason: "guard_unavailable" };
    if (read_config() != before) {
        if (inherited) return { status: "failed", reason: "concurrent_change", guard: "active" };
        if (!restore_guard(true)) return { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        return { status: "failed", reason: "concurrent_change" };
    }
    if (!atomic(CONFIG, content)) {
        if (inherited) return { status: "failed", reason: "replace_failed", guard: "active" };
        if (!restore_guard(true)) return { status: "needs_attention", reason: "replace_failed", guard: "active" };
        return { status: "failed", reason: "replace_failed" };
    }
    let result = null;
    let valid = success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/config/validator.uc", "validate-runtime" ]);
    let target = valid ? reload(reason) : "invalid";
    // A guard that a failed lifecycle transition kept, before or during this
    // reload, leaves no coherent runtime whatever the reload's exit status,
    // and the lifecycle refuses every reload over it: the guard stays, LKG
    // does not move, and the result names the restart it needs (UC-019).
    let guarded = target != "stopped" && runtime_guard_settled();
    let holds = config_holds(content);
    if (target == "ran" && !guarded && (holds || apply_mode)) {
        if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else result = on_success();
    }
    else if (target == "ran" && (holds || apply_mode))
        result = { status: "needs_attention", reason: "runtime_guard_active", guard: "active" };
    else if (!holds) {
        let saved = save_concurrent_edit([ pre.snapshot.id, ...(keep || []) ]);
        // A reload that ran proved a coherent runtime, and a stopped runtime
        // has nothing a guard could protect (see above).
        if ((target != "ran" || guarded) && target != "stopped")
            result = { status: "needs_attention", reason: "config_changed_during_transaction", guard: "active", saved_snapshot: saved };
        else if (!restore_guard(true))
            result = { status: "needs_attention", reason: "guard_release_failed", guard: "active", saved_snapshot: saved };
        else {
            result = { status: "needs_attention", reason: "config_changed_during_transaction", guard: "inactive", saved_snapshot: saved };
            if (target == "stopped") result.runtime = "stopped";
        }
    }
    else if (target == "stopped" && on_stopped != null) {
        if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else result = on_stopped();
    }
    else if (!atomic(CONFIG, before))
        result = { status: "needs_attention", reason: "config_rollback_failed", guard: "active" };
    else {
        // No rollback reload over a kept guard: the lifecycle would refuse
        // it. The previous configuration waits in the file for the restart.
        let rollback = guarded ? "guarded" : reload(reason);
        if (rollback != "guarded" && rollback != "stopped" && runtime_guard_settled()) rollback = "guarded";
        if (rollback == "guarded")
            result = { status: "needs_attention", reason: "runtime_guard_active", guard: "active" };
        else if (rollback == "stopped") {
            if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
            else result = { status: "failed", reason: target == "invalid" ? "target_invalid" : "service_stopped",
                guard: "inactive", runtime: "stopped" };
        }
        else if (rollback != "ran")
            result = { status: "needs_attention", reason: rollback == "queued" ? "rollback_reload_queued" : "runtime_rollback_failed", guard: "active" };
        else if (!restore_guard(true)) result = { status: "needs_attention", reason: "guard_release_failed", guard: "active" };
        else if (pre.snapshot.config_hash == lkg_hash() && !atomic(LKG, pre.snapshot.id + "\n"))
            result = { status: "needs_attention", reason: "lkg_update_failed", guard: "inactive" };
        else result = { status: "recovered", reason: target == "queued" ? "target_reload_queued" : "target_reload_failed", guard: "inactive" };
    }
    result.started = true;
    return result;
}
// Whether the rule an autotune apply changed (mutation: { section, option
// "nfqws_opt", to }) still runs the candidate's strategy in `content`: an
// enabled zapret rule whose nfqws_opt is the candidate's (whitespace as
// autotune/apply.uc normalizes it; its status reports the same as
// unverified_strategy). A configuration this reader cannot load might have
// it (fail closed).
function runs_strategy(content, mutation) {
    if (type(mutation) != "object" || type(mutation.section) != "string" || type(mutation.to) != "string") return false;
    let sections = uci_sections(content);
    if (sections == null) return true;
    let words = (v) => join(" ", filter(split(v, /[ \t\r\n]+/), (w) => w != ""));
    for (let s in sections) {
        if (s.type != "section" || s.name !== mutation.section) continue;
        let opt = {};
        for (let o in s.options) if (!o.list) opt[o.name] = o.value;
        let enabled = opt.enabled == null || index([ "1", "true", "yes", "on" ], lc(opt.enabled)) >= 0;
        return enabled && opt.action == "zapret" && opt.nfqws_opt != null && words(opt.nfqws_opt) == words(mutation.to);
    }
    return false;
}
// Why the configuration may not become last-known-working because of an
// autotune apply, or null. A start or a reload proves that a configuration
// runs, not that an autotune candidate works: a candidate is confirmed only
// by the apply that verified it in production (confirm-working autotune).
// Nothing else confirms while an apply is running, while its record cannot
// be read (it may hide an unresolved apply), or while a record that still
// waits for a decision names the configuration as its candidate: an
// interrupted or crashed verification, a failed one whose rollback did not
// finish (UC-020, UC-069). A configuration edited on top of a candidate
// that never passed its verification (one kept by the automatic rollback
// because it was edited during the check, UC-017) is no candidate any more,
// but while the rule still runs the candidate's strategy it carries what
// has not been, or has just failed to be, verified.
function autotune_objection(content) {
    if (fs.stat(AUTOTUNE_APPLY_STATE) == null) return null;
    let record = null;
    try { record = json(value(fs.readfile(AUTOTUNE_APPLY_STATE))); } catch (e) { record = null; }
    if (type(record) != "object" || type(record.phase) != "string") return "autotune_apply_unreadable";
    if (record.mutation == null) return null;
    let finished = index(AUTOTUNE_TERMINAL_PHASES, record.phase) >= 0;
    if (!finished && require("autotune.lock").held()) return "autotune_apply_in_progress";
    // A decided record objects to nothing: nothing more is read or parsed
    // (this runs in every start and reload).
    let undecided = !finished || record.phase == "needs_attention" || (record.phase == "failed" && record.rollback_available === true);
    if (!undecided) return null;
    let hash = sha(content);
    let candidate = hash != "" && (hash == record.candidate_hash ||
        (record.candidate_fingerprint != null && user_fingerprint(content) == record.candidate_fingerprint));
    if (!candidate && record.applied !== true) candidate = runs_strategy(content, record.mutation);
    return candidate ? "autotune_apply_unresolved" : null;
}
// expected (optional): the hash, or the user fingerprint, of the
// configuration the caller means to replace. The automatic rollback of
// autotune passes its candidate's: a configuration edited since (during the
// verification) is not the caller's to replace. It is kept, saved as a
// snapshot, and the answer is needs_attention before anything changes
// (UC-017).
function do_restore(id, expected) {
    if (expected != "" && !valid_hash(expected)) return { status: "failed", reason: "invalid_expected_hash" };
    let target = read_snapshot(id, true);
    if (target == null) return { status: "failed", reason: "invalid_snapshot" };
    let before = read_config();
    if (before == null) return { status: "failed", reason: "config_unavailable" };
    if (expected != "" && sha(before) != expected && user_fingerprint(before) != expected)
        return { status: "needs_attention", reason: "config_changed_during_transaction", saved_snapshot: save_concurrent_edit([ id ]) };
    // Refused before anything changes: staged changes would ride along, the
    // reload would only be queued behind a live lifecycle action, or the
    // lifecycle would refuse it over a guard a failed transition kept (a
    // restart removes that guard; UC-019).
    if (staged_changes()) return { status: "failed", reason: "uncommitted_uci_changes" };
    let action = service_action();
    if (action != null) return { status: "busy", reason: action };
    // A guard seen as a lifecycle action takes the lock may be its own.
    if (runtime_guard_kept())
        return service_action() != null ? { status: "busy", reason: "service_action_in_progress" } :
            { status: "failed", reason: "runtime_guard_active" };
    let pre = create("automatic", "pre-restore", false, [ id ]);
    if (pre.status != "created") return { status: "failed", reason: "pre_restore_snapshot_failed" };
    if (sha(before) != sha(read_config())) return { status: "failed", reason: "concurrent_change" };
    return guarded_replace(before, target.content, pre, () => {
        if (!atomic(LKG, id + "\n")) return { status: "needs_attention", reason: "lkg_update_failed", guard: "inactive" };
        return { status: "success", snapshot: metadata(target), changes: diff(before, target.content) };
    }, "config-restore", false, () => ({
        // Replaced and validated; no runtime proved it, so LKG stays.
        status: "restored_not_started", reason: "service_stopped", guard: "inactive",
        snapshot: metadata(target), changes: diff(before, target.content)
    }), [ id ]);
}
// Apply a candidate configuration prepared elsewhere (DPI autotune stage 5)
// through the same transaction as a restore. The current configuration must
// still be the one the candidate was derived from (expected_hash), and it is
// saved first as a "before-autotune" snapshot for the caller's rollback. LKG
// is left untouched on success: the caller confirms it after its own checks.
function do_apply(candidate_file, expected_hash, keep_id) {
    let keep = valid_id(value(keep_id)) ? [ value(keep_id) ] : [];
    let content = fs.readfile(value(candidate_file));
    if (content == null || length(content) > MAX_CONFIG) return { status: "failed", reason: "candidate_unavailable" };
    let before = read_config();
    if (before == null) return { status: "failed", reason: "config_unavailable" };
    if (sha(before) != value(expected_hash)) return { status: "stale", reason: "config_changed" };
    if (content == before) return { status: "no_change", reason: "candidate_equals_config" };
    // An apply never changes a runtime that an explicit stop holds down:
    // nothing could verify the candidate (D-15, UC-056). One not started
    // since boot is refused by the caller (autotune/apply.uc); here its
    // reload answers "stopped" and the candidate is put back.
    if (fs.stat(STOP_REQUESTED) != null) return { status: "stale", reason: "service_stopped" };
    // A queued reload without a live owner is no refusal, as for a restore:
    // the transaction's own reload drains it while the guard stands.
    let action = service_action();
    if (action != null) return { status: "stale", reason: action };
    if (runtime_guard_kept())
        return { status: "stale", reason: service_action() ?? "runtime_guard_active" };
    // Room for the before-autotune snapshot and for the pre-restore snapshot
    // of a later rollback, which may not remove the before-autotune one. A
    // manual LKG stays protected after the candidate is confirmed, so it
    // costs one more slot.
    let working = read_snapshot(trim(value(fs.readfile(LKG))), false);
    if (headroom(keep) < (working != null && working.kind == "manual" ? 3 : 2)) return { status: "failed", reason: "snapshot_retention_full" };
    let pre = create("automatic", "before-autotune", false, keep);
    if (pre.status != "created") return { status: "failed", reason: "pre_apply_snapshot_failed" };
    if (sha(before) != sha(read_config())) return { status: "failed", reason: "concurrent_change", pre_snapshot: pre.snapshot.id };
    let result = guarded_replace(before, content, pre, () => ({ status: "success", changes: diff(before, content) }), "autotune", true, null, keep);
    result.pre_snapshot = pre.snapshot.id;
    return result;
}
let mode = value(ARGV[0]);
// The list is read-only output: the hash of the whole config (secrets
// included) stays internal (UC-150).
if (mode == "list") {
    let result = fs.stat(ROOT) == null ? [] : list_snapshots();
    for (let item in result) delete item.config_hash;
    print(sprintf("%J\n", result));
    exit(0);
}
if (mode == "diff") {
    let item = read_snapshot(value(ARGV[1]), true);
    let current = read_config();
    if (item == null || current == null) exit(1);
    print(sprintf("%J\n", diff(item.content, current)));
    exit(0);
}
if (mode == "fixture-diff") {
    print(sprintf("%J\n", diff(value(fs.readfile(ARGV[1])), value(fs.readfile(ARGV[2])))));
    exit(0);
}
if (index([ "create", "delete", "restore", "apply", "confirm-working" ], mode) < 0) exit(1);
if (!acquire()) {
    print(sprintf("%J\n", lock_busy ?
        { status: "busy", reason: "snapshot_operation_in_progress" } :
        { status: "failed", reason: "lock_unavailable" }));
    exit(1);
}
let answer = { status: "failed" };
if (mode == "create") {
    let kind = value(ARGV[1] || "manual");
    if (index([ "manual", "automatic" ], kind) >= 0)
        answer = create(kind, kind == "manual" ? "manual" : "before-reload", kind == "automatic");
    // Automatic snapshots are routine; only a manual one is a history event.
    if (kind == "manual" && answer.status == "created")
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "snapshot_create", "success" ]);
}
else if (mode == "delete") {
    let id = value(ARGV[1]);
    let protection = autotune_snapshot_protection();
    if (valid_id(id) && !recovery_protects(protection, id) && id != trim(value(fs.readfile(LKG))) && read_snapshot(id, true) != null && fs.unlink(snapshot_path(id))) {
        answer = { status: "deleted" };
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "snapshot_delete", "success" ]);
    }
    else if (valid_id(id) && recovery_protects(protection, id))
        answer = { status: "failed", reason: "protected_for_recovery" };
}
else if (mode == "restore") {
    answer = do_restore(value(ARGV[1]), value(ARGV[2]));
    // A busy refusal changed nothing and is not a restore attempt, nor is a
    // refusal because of staged uci changes or a kept runtime guard.
    // A restore that an explicit stop kept from starting the runtime is no
    // success: nothing verified it.
    if (answer.status != "busy" && answer.reason != "uncommitted_uci_changes" &&
        (answer.started || answer.reason != "runtime_guard_active"))
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "restore",
            answer.status == "success" ? "success" : answer.status == "recovered" ? "recovered" :
            answer.status == "restored_not_started" ? "not_started" : "failure" ]);
}
else if (mode == "apply") {
    answer = do_apply(ARGV[1], ARGV[2], ARGV[3]);
    // Health records a configuration transaction only when one was started.
    if (answer.started)
        success([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "record", "autotune_apply",
            answer.status == "success" ? "success" : answer.status == "recovered" ? "recovered" : "failure" ]);
}
else if (mode == "confirm-working") {
    // A start or reload of the lifecycle; "autotune": the apply that has
    // just verified its candidate in production.
    let content = read_config();
    let objection = content == null || value(ARGV[1]) == "autotune" ? null : autotune_objection(content);
    if (objection != null) answer = { status: "not_confirmed", reason: objection };
    else {
        let found = create("automatic", "last-known-working", true);
        if (found.snapshot != null &&
            (trim(value(fs.readfile(LKG))) == found.snapshot.id || atomic(LKG, found.snapshot.id + "\n")))
            answer = { status: "confirmed" };
    }
}
release();
print(sprintf("%J\n", answer));
exit(index([ "failed", "needs_attention", "busy", "not_confirmed" ], answer.status) >= 0 ? 1 : 0);
