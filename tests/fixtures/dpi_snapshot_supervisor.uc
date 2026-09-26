let fs = require("fs");
let child_pidfile = ARGV[4];
if (ARGV[0] != "supervisor" || child_pidfile == null)
    exit(2);
if (ARGV[1] == "fail")
    exit(1);
if (ARGV[1] == "nochild") {
    system("sh -c 'sleep 300 & echo $! > " + child_pidfile + ".observed; wait'");
    exit(0);
}
let command = "sleep 300 & echo $! > '" + child_pidfile + "'; echo $! > '" + child_pidfile + ".observed'; wait";
system("sh -c '" + command + "'");
