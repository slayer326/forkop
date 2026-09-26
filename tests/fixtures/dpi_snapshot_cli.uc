let snapshot = require("providers.runtime_snapshot");
let mode = ARGV[0];
let library = ARGV[1];
let runtime = ARGV[2];
let pid_dir = ARGV[3];
let child_pid_dir = ARGV[4];
let log_dir = ARGV[5];
let path = ARGV[6];
if (mode == "snapshot")
    exit(snapshot.snapshot(pid_dir, child_pid_dir, runtime, library, path) ? 0 : 1);
if (mode == "restore")
    exit(snapshot.restore(path, pid_dir, child_pid_dir, log_dir, runtime, library, "sleep", [ "sleep", "300" ]) ? 0 : 1);
if (mode == "record-test") {
    let identity = require("core.process_identity");
    exit(identity.record(pid_dir + "/" + ARGV[8] + ".pid", ARGV[7]) ? 0 : 1);
}
if (mode == "kill-restored") {
    let identity = require("core.process_identity");
    exit(identity.signal(pid_dir + "/example.pid", "ucode",
        [ "ucode", "-L", library, runtime, "supervisor", "example" ], false, "KILL", true) ? 0 : 1);
}
exit(2);
