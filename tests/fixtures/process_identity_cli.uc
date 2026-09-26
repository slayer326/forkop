let identity = require("core.process_identity");
let mode = ARGV[0];
let path = ARGV[1];
let pid = ARGV[2];

if (mode == "record")
    exit(identity.record(path, pid) ? 0 : 1);
if (mode == "record-signal")
    exit(identity.signal_record({ pid: ARGV[1], ticks: ARGV[2] }, ARGV[3],
        [ ARGV[3], ARGV[4] ], true, ARGV[5]) ? 0 : 1);
if (mode == "matches")
    exit(identity.matches(path, ARGV[2], [ ARGV[2], ARGV[3] ], true, ARGV[4] == "1") != "" ? 0 : 1);
if (mode == "signal")
    exit(identity.signal(path, ARGV[2], [ ARGV[2], ARGV[3] ], true, ARGV[4]) ? 0 : 1);
if (mode == "worker-signal")
    exit(identity.signal(path, "ucode", [ "ucode", "-L", ARGV[2], ARGV[3], "worker" ], true, ARGV[4]) ? 0 : 1);
if (mode == "promote-child")
    exit(identity.promote_legacy_child(path, ARGV[2], [ "ucode", "-L", ARGV[3], ARGV[4], "supervisor", "example" ], "sleep", [ "sleep", "300" ]) ? 0 : 1);
exit(2);
