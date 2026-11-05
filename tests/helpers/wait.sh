# shellcheck shell=sh
# Bounded polling for tests: wait for an observable state (a process has
# exec'd, a lock is held, a file appeared) instead of sleeping for a fixed
# time. A fixed sleep assumes the scheduler reaches that state in time, which
# fails under load; a shell job's $! is known before the command is exec'd.
# POSIX sh and bash compatible; sourced by the tests that need it.

# wait_until SECONDS COMMAND [ARG...]
# Runs COMMAND every 50 ms until it succeeds; returns 1 once SECONDS of wall
# clock time have passed without success.
wait_until() {
    wait_until_deadline=$(($(date +%s) + $1))
    shift
    until "$@"; do
        [ "$(date +%s)" -lt "$wait_until_deadline" ] || return 1
        sleep 0.05
    done
}

# process_running PID
# True while PID runs code: a zombie (Z) or dead (X) process does not. A
# killed process reparented to a PID 1 that does not reap children stays a
# zombie, and kill -0 still succeeds for it. Without /proc, kill -0 decides.
process_running() {
    kill -0 "$1" 2>/dev/null || return 1
    if IFS= read -r process_running_stat 2>/dev/null <"/proc/$1/stat"; then
        process_running_stat="${process_running_stat##*) }"
        case "${process_running_stat%% *}" in
            Z | X) return 1 ;;
        esac
        return 0
    fi
    kill -0 "$1" 2>/dev/null
}

process_gone() {
    ! process_running "$1"
}

# process_exec_is PID NAME
# True once PID runs the executable NAME (compared by basename), i.e. the
# fork of a background job has exec'd its command. Some distros install
# coreutils under a "gnu" prefix and only symlink the plain name to it
# (/usr/bin/sleep -> gnusleep): /proc/PID/exe resolves the real binary.
process_exec_is() {
    process_exec_is_exe="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
    [ "${process_exec_is_exe##*/}" = "$2" ] || [ "${process_exec_is_exe##*/}" = "gnu$2" ]
}

# lock_held FILE
# True while another process holds an flock on FILE.
lock_held() {
    ! flock -n "$1" true
}

# file_nonempty FILE
file_nonempty() {
    [ -s "$1" ]
}
