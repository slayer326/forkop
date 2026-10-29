// Runtime directory locks: reload.lock, subscription-update.lock, the latency
// test and component update check locks. Global lock order: service/state.uc.
//
// Same owner-record scheme as the config snapshot lock (config/snapshots.uc):
// the lock is a directory holding
// one "owner.<pid>.<start ticks>" record. The record is written into a
// private directory that an atomic rename then publishes as the lock, so no
// one ever sees the lock without its owner. The owner is the process named
// by the caller (a service/state.uc helper takes the lock for its caller). It
// holds the lock only while a process with that pid and start time runs: a
// dead owner or a pid reused by another process leaves a stale lock, which
// the next acquirer breaks. The name is unique per process lifetime, so
// breaking a stale lock or releasing one's own never removes the record of a
// lock that replaced it.
//
// The previous package version created the lock with mkdir and then wrote
// "<pid>\n[<start ticks>\n]" to <lock>/pid. Such a record holds the lock
// while its owner runs, like an owner record. A lock without any owner record
// is one whose creator has not written its pid yet: it counts as held for
// SETUP_GRACE_SECONDS, then as abandoned. One window stays open against a
// previous-version acquirer still running during an upgrade: its mkdir
// between our inspection and our rename leaves an empty directory that the
// rename replaces, and it then writes its pid into our lock. Closing it needs
// a rename that never replaces (renameat2 RENAME_NOREPLACE), which fs.rename
// does not offer.
let fs = require("fs");
let identity = require("core.process_identity");

const SETUP_GRACE_SECONDS = 5;
const LEGACY_RECORD = "pid";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function valid_pid(pid) {
    return match(as_string(pid), /^[1-9][0-9]*$/) != null;
}

function self_pid() {
    let pid = as_string(fs.readlink("/proc/self"));
    return valid_pid(pid) ? pid : "";
}

// The owner a record names, { pid, ticks } (ticks "" for a previous-version
// record without them), or null.
function record_owner(lock_dir, name) {
    let parsed = match(name, /^owner\.([1-9][0-9]*)\.([0-9]+)$/);
    if (parsed != null)
        return { pid: parsed[1], ticks: parsed[2] };
    if (name != LEGACY_RECORD)
        return null;
    let lines = split(as_string(fs.readfile(lock_dir + "/" + name)), "\n");
    let pid = trim(as_string(lines[0]));
    let ticks = trim(as_string(lines[1]));
    if (!valid_pid(pid) || (ticks != "" && match(ticks, /^[0-9]+$/) == null))
        return null;
    return { pid, ticks };
}

function owner_running(owner) {
    if (owner == null)
        return false;
    let ticks = identity.start_ticks(owner.pid);
    return ticks != "" && (owner.ticks == "" || ticks == owner.ticks);
}

// { state: "absent" | "other" | "held" | "setup" | "stale" }: "other" is not
// a lock directory, "held" names the running owner, "stale" lists the entries
// to remove.
function inspect(lock_dir) {
    let stat = fs.lstat(lock_dir);
    if (stat == null)
        return { state: "absent" };
    if (stat.type != "directory")
        return { state: "other" };
    let entries = fs.lsdir(lock_dir);
    if (entries == null)
        return { state: "absent" };
    let recorded = false;
    for (let name in entries) {
        let owner = record_owner(lock_dir, name);
        if (owner == null)
            continue;
        if (owner_running(owner))
            return { state: "held", owner: owner.pid };
        recorded = true;
    }
    let age = time() - int(stat.mtime || 0);
    if (!recorded && age >= 0 && age < SETUP_GRACE_SECONDS)
        return { state: "setup" };
    return { state: "stale", entries };
}

function remove_dir(dir) {
    for (let name in fs.lsdir(dir) || [])
        fs.unlink(dir + "/" + name);
    return fs.rmdir(dir);
}

function acquire(lock_dir, owner_pid) {
    lock_dir = as_string(lock_dir);
    owner_pid = as_string(owner_pid);
    let ticks = valid_pid(owner_pid) ? identity.start_ticks(owner_pid) : "";
    let pid = self_pid();
    let own_ticks = identity.start_ticks(pid);
    if (lock_dir == "" || ticks == "" || own_ticks == "")
        return false;

    let name = "owner." + owner_pid + "." + ticks;
    let pending = lock_dir + ".new." + pid + "." + own_ticks;
    remove_dir(pending);
    if (!fs.mkdir(pending, 0755) || fs.writefile(pending + "/" + name, owner_pid + "\n" + ticks + "\n") == null) {
        remove_dir(pending);
        return false;
    }

    let acquired = false;
    for (let attempt = 0; attempt < 3 && !acquired; attempt++) {
        let current = inspect(lock_dir);
        if (current.state == "held" || current.state == "setup")
            break;
        if (current.state == "other")
            // Not a lock directory; never follow a symlink here.
            fs.unlink(lock_dir);
        else if (current.state == "stale")
            for (let entry in current.entries) {
                // A previous-version contender rewrites <lock>/pid under the
                // same name: never remove a record that names a running owner
                // by now. The rename below then fails on the lock it kept.
                if (owner_running(record_owner(lock_dir, entry)))
                    break;
                if (!fs.unlink(lock_dir + "/" + entry))
                    fs.rmdir(lock_dir + "/" + entry);
            }
        // rename() refuses a populated lock; an empty one was released or
        // just emptied above.
        acquired = fs.rename(pending, lock_dir);
    }
    if (!acquired)
        remove_dir(pending);
    return acquired;
}

// Releases only the owner's own record: the named owner's or, without one,
// the record of this process or of an ancestor (a service/state.uc helper
// releasing for its caller, as callers of the previous version run it). The
// lock of anyone else stays.
function release(lock_dir, owner_pid) {
    lock_dir = as_string(lock_dir);
    owner_pid = as_string(owner_pid);
    if (lock_dir == "")
        return false;

    let pid = self_pid();
    let released = false;
    for (let name in fs.lsdir(lock_dir) || []) {
        let owner = record_owner(lock_dir, name);
        if (!owner_running(owner))
            continue;
        if (owner_pid != "" ? owner.pid != owner_pid :
            owner.pid != pid && !identity.descendant_of(pid, owner.pid))
            continue;
        if (fs.unlink(lock_dir + "/" + name))
            released = true;
    }
    if (released)
        fs.rmdir(lock_dir);
    return released;
}

// The pid of the running owner, or "" when the lock is free or stale.
function owner(lock_dir) {
    let current = inspect(as_string(lock_dir));
    return current.state == "held" ? current.owner : "";
}

// Held by a running owner, or still being set up.
function busy(lock_dir) {
    let state = inspect(as_string(lock_dir)).state;
    return state == "held" || state == "setup";
}

return { acquire, release, owner, busy };
