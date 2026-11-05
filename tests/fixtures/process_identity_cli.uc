let identity = require("core.process_identity");
let mode = ARGV[0];
let path = ARGV[1];
let pid = ARGV[2];

// Distros may install coreutils under a "gnu" prefix (/usr/bin/sleep ->
// gnusleep); /proc/<pid>/exe then names the real binary while argv[0] keeps
// the invoked name. The test exports the resolved name for exe comparisons.
let sleep_exe = getenv("SLEEP_EXE_NAME") || "sleep";
function exe_name(expected) { return expected == "sleep" ? sleep_exe : expected; }

if (mode == "record")
    exit(identity.record(path, pid) ? 0 : 1);
if (mode == "record-signal")
    exit(identity.signal_record({ pid: ARGV[1], ticks: ARGV[2] }, exe_name(ARGV[3]),
        [ ARGV[3], ARGV[4] ], true, ARGV[5]) ? 0 : 1);
if (mode == "matches")
    exit(identity.matches(path, ARGV[2], [ ARGV[2], ARGV[3] ], true, ARGV[4] == "1") != "" ? 0 : 1);
if (mode == "signal")
    exit(identity.signal(path, ARGV[2], [ ARGV[2], ARGV[3] ], true, ARGV[4]) ? 0 : 1);
if (mode == "worker-signal")
    exit(identity.signal(path, "ucode", [ "ucode", "-L", ARGV[2], ARGV[3], "worker" ], true, ARGV[4]) ? 0 : 1);
if (mode == "promote-child")
    exit(identity.promote_legacy_child(path, ARGV[2], [ "ucode", "-L", ARGV[3], ARGV[4], "supervisor", "example" ], sleep_exe, [ "sleep", "300" ]) ? 0 : 1);
exit(2);
