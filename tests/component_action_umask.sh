#!/usr/bin/env bash
# rpcd runs with umask 0077 and the panel's component actions inherited it.
# The Zapret-Manager web installer then created /opt as 0700, and Zapret2's
# nfqws2, which drops to the daemon user, could no longer read its own files
# and exited at every start. A component action must install with umask 022,
# while its job output stays private.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

fake_lib="$WORK_DIR/lib"
job_dir="$WORK_DIR/jobs"
state_file="$job_dir/manual.json"
output_file="$job_dir/manual.out"
mkdir -p "$fake_lib/core" "$fake_lib/config" "$fake_lib/components" "$fake_lib/service" "$job_dir"

cat >"$fake_lib/core/uci.uc" <<'UCODE'
function get_all(_config, _section) {
    return {};
}

function section_objects(_config, _type) {
    return [];
}

return {
    get_all,
    section_objects
};
UCODE

cat >"$fake_lib/config/connections.uc" <<'UCODE'
return {};
UCODE

cat >"$fake_lib/service/state.uc" <<'UCODE'
#!/usr/bin/env ucode
exit(0);
UCODE

# Stands in for an installer: records the umask and the mode of the job
# output file it writes to, and creates a missing parent directory the way
# `mkdir -p /opt/zapret-manager-luci` does. The worker removes the output
# file once the job state holds the result.
cat >"$fake_lib/components/action.uc" <<'UCODE'
#!/usr/bin/env ucode
let root = getenv("TEST_INSTALL_ROOT");
system("umask >'" + root + "/umask'; stat -L -c %a /proc/$$/fd/1 >'" + root + "/output-mode'; " +
    "mkdir -p '" + root + "/opt/zapret-manager-luci'");
print(sprintf("%J\n", { success: true, component: ARGV[1], action: ARGV[2], message: "installed", changed: 1 }));
UCODE

install_root="$WORK_DIR/root"
mkdir -p "$install_root"
(
  umask 077
  TEST_INSTALL_ROOT="$install_root" \
    FORKOP_LIB="$fake_lib" \
    UPDATES_JOB_DIR="$job_dir" \
    ucode -L "$fake_lib" -L "$FORKOP_LIB" "$UPDATES_UC" \
    component-action-worker "$state_file" "$output_file" zapret_manager install
)

[ "$(cat "$install_root/umask" 2>/dev/null)" = "0022" ] ||
  fail "a component action ran with umask $(cat "$install_root/umask" 2>/dev/null) instead of 0022"
[ "$(stat -c %a "$install_root/opt")" = "755" ] ||
  fail "a directory an installer created is $(stat -c %a "$install_root/opt"), not 755"
[ "$(cat "$install_root/output-mode" 2>/dev/null)" = "600" ] ||
  fail "the job output file was $(cat "$install_root/output-mode" 2>/dev/null), not private"
grep -q '"installed"' "$state_file" ||
  fail "the action result did not reach the job state"

printf 'component action umask checks passed\n'
