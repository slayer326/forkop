// The list update worker (components/updates.uc list_update) records itself
// in PID_FILE for its whole run and removes the record before its final
// reload. It runs its DNS probe and downloads without reload.lock (UC-057),
// but it reads its sources when it starts and applies them only in that
// final reload, so init.d queues every reload that arrives meanwhile
// (service/initd.uc), as when it held reload.lock for the whole update. A
// caller whose reload has to run now treats a running worker like a live
// reload.lock owner (config/snapshots.uc).
//
// Only the list worker records this file, so any updates.uc process it
// names is that worker, whatever its mode; a PID that a dead worker left
// there is not (core/process_identity.uc, UC-014).
let identity = require("core.process_identity");

const PID_FILE = getenv("FORKOP_LIST_UPDATE_PID_FILE") || "/var/run/forkop_list_update.pid";

function running(lib_dir) {
    lib_dir = lib_dir == null ? "" : "" + lib_dir;
    return identity.matches(PID_FILE, "ucode",
        [ "ucode", "-L", lib_dir, lib_dir + "/components/updates.uc" ], false, false) != "";
}

return { PID_FILE, running };
