let identity = require("core.process_identity");

if (ARGV[0] == "record" && ARGV[1] != null && ARGV[2] != null)
    exit(identity.record(ARGV[2], ARGV[1]) ? 0 : 1);

exit(1);
